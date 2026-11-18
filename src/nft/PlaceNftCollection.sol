// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IPlaceNftFactory, IPlaceNftSwapper} from "./interfaces/IPlaceNft.sol";

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

/// @title PlaceNftCollection
/// @notice An ERC-721 collection of the Place NFT launchpad (a clone per collection, made by PlaceNftFactory).
///         An NFT launch works like a token launch: the collection is paired with a token and has a mint economy.
///
///         - **Pair token** (`token`): required for a paid mint. A Place token (its launch pool) or any token with
///           a route ETH -> token in the PlaceRewardTokenRegistry (1–3 Uniswap v4 hops). The factory refuses a
///           token without a route. A free collection may have no pair (royalties only, holders paid in ETH).
///         - **Mint**: the price is always in ETH; optionally also payable in the pair token at the ETH equivalent
///           at the moment of the mint (PlacePriceGuard: the buyer pays the larger of the reference and the spot
///           amounts; refused while the price is not ready or deviates).
///         - **Economy** of every payment and of every royalty (ERC-2981, 0–10%): 20% to the platform, the rest
///           split as the creator set at creation (immutable): creator / NFT holders / buyback & burn.
///           * Holders pool: the holders share, in the **reward token** the creator picked (ETH, the pair token, or
///             any token with a registry route from ETH), is paid out over `POOL_DAYS` days in equal daily
///             portions. A portion accrues at 00:00 UTC to every NFT that exists at that moment, equally per NFT.
///             A new income re-spreads what is left plus the income over the next `POOL_DAYS` days (the
///             StakingRewards rate / period-finish scheme, by whole UTC days); the pool ends `POOL_DAYS` days
///             after the last income. Income that arrives while no NFT exists goes to the creator.
///           * A holders share in another asset is swapped into the reward token in the same transaction and
///             joins the pool when the swap happens.
///           * Burn: payments in the pair token are burned at once; the ETH part buys the pair token in the same
///             mint transaction and burns it.
///           * Swaps go through PlaceNftSwapper (guard reference output minus the guard's max deviation and the
///             registry's per-hop impact). If a swap cannot run safely the mint still succeeds: the amount waits
///             and every later mint (or anyone, with `processPending`) tries again.
///         - **Royalties** in ETH arrive as plain transfers and wait for the next mint or `processPending`; WETH
///           and ERC-20 royalties are split by `processPending(asset)` (any ERC-20 other than the pair token: 20%
///           platform, the rest to the creator).
///         - **Transfers**: what an NFT accrued and its owner did not claim stays with the previous owner (credited to
///           its address, claimed later); later accruals go to the new owner.
/// @dev    No keeper: the pool accrues lazily from any transaction by the number of whole UTC days passed. Every
///         change of the NFT count (a mint) accrues first, so the count is constant between two accruals.
///         `reserved[asset]` is everything the contract owes; anything above it is an unprocessed royalty.
contract PlaceNftCollection is ERC721, IERC2981, Ownable2Step, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    enum Kind {
        Unique,
        Edition
    }

    /// @notice Split of everything after the platform share, in bps (sum 10 000).
    struct Economy {
        uint16 creatorBps;
        uint16 holdersBps;
        uint16 burnBps;
    }

    struct InitParams {
        string name;
        string symbol;
        Kind kind;
        string baseURI; // Unique: folder URI ending in "/"; Edition: the metadata URI of every token
        string uriSuffix; // Unique only, e.g. ".json"
        string contractURI; // collection metadata: description, logo, banner
        uint32 maxSupply; // Unique: > 0; Edition: 0 = open edition
        uint32 maxPerWallet; // 0 = no limit
        uint64 mintStart; // 0 = at once
        uint64 mintEnd; // 0 = no end
        uint128 mintPrice; // wei per NFT; 0 = free mint
        address token; // the pair token (required for a paid mint)
        bool tokenPayments; // also accept the pair token at the ETH-equivalent price
        address rewardToken; // holders are paid in it: ETH (0), the pair token, or a token with a route from ETH
        uint16 royaltyBps; // 0–1 000
        Economy economy;
        PoolKey launchPool; // the pair token's Place launch pool (tickSpacing 0 = none; verified by the factory)
    }

    uint16 public constant PLATFORM_BPS = 2_000;
    uint16 public constant MAX_ROYALTY_BPS = 1_000;
    /// @notice Days over which every holders income is paid out.
    uint256 public constant POOL_DAYS = 30;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ACC = 1e36;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    address internal constant ETH = address(0);

    address public factory;
    address public token;
    address public rewardToken;
    bool public official;
    Kind public kind;
    bool public tokenPayments;
    bool public metadataFrozen;
    uint16 public royaltyBps;
    uint32 public maxSupply;
    uint32 public maxPerWallet;
    uint32 public totalMinted;
    uint64 public mintStart;
    uint64 public mintEnd;
    uint128 public mintPrice;
    Economy internal _economy;
    PoolKey internal _launchPool;
    string internal _name;
    string internal _symbol;
    string internal _baseURIValue;
    string public uriSuffix;
    string public contractURI;

    mapping(address account => uint32 minted) public mintedBy;
    /// @notice What the contract owes in `asset`.
    mapping(address asset => uint256 amount) public reserved;
    mapping(address asset => uint256 amount) public creatorOwed;
    mapping(address asset => uint256 amount) public platformOwed;
    /// @notice ETH waiting to buy back and burn the pair token.
    uint256 public buybackPending;
    /// @notice Holders shares in `asset` (not the reward token) waiting to be swapped into the pool.
    mapping(address asset => uint256 amount) public pendingHolders;

    /// @notice Holders pool: reward token per UTC day, scaled by 1e36.
    uint256 public rewardRate;
    /// @notice Last UTC day (days since 1970-01-01) that accrues a portion; the pool ends after it.
    uint64 public periodFinish;
    /// @notice UTC day up to which the pool has accrued.
    uint64 public lastAccrualDay;
    /// @notice Reward token accrued per NFT, ever (scaled by 1e36).
    uint256 public accPerNft;
    mapping(uint256 tokenId => uint256 acc) internal _paid;
    /// @notice Settled holder rewards of an address, in the reward token (previous owners after a transfer).
    mapping(address account => uint256 amount) public credit;
    /// @notice Pair tokens burned, ever.
    uint256 public totalBurned;

    event CollectionInitialized(
        address indexed creator, address indexed token, address rewardToken, bool official, Kind kind
    );
    event Minted(address indexed to, uint256 firstTokenId, uint256 quantity, address indexed asset, uint256 paid);
    event RevenueSplit(
        address indexed asset, uint256 platform, uint256 creator, uint256 holders, uint256 burn, bool royalty
    );
    event HoldersFunded(uint256 amount, uint256 rewardRate, uint64 periodFinish);
    event HoldersConverted(address indexed asset, uint256 amountIn, uint256 rewardOut);
    event ConversionDeferred(address indexed asset, uint256 amount);
    event HoldersClaimed(address indexed account, uint256 amount);
    event Paid(
        address indexed creator,
        address indexed platform,
        address indexed asset,
        uint256 creatorAmount,
        uint256 platformAmount
    );
    event TokensBurned(uint256 amount, uint256 ethIn);
    event MintSet(uint128 price, uint64 start, uint64 end, bool tokenPayments);
    event RoyaltySet(uint16 bps);
    event BaseURISet(string baseURI, string uriSuffix);
    event MetadataFrozen();
    /// @dev ERC-4906 and ERC-7572.
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event ContractURIUpdated();

    error InvalidConfig();
    error MintClosed();
    error SoldOut();
    error WalletLimit();
    error WrongPayment(uint256 sent, uint256 expected);
    error TokenPaymentsDisabled();
    error TokenAmountAboveMax(uint256 due, uint256 maxIn);
    error NotTokenOwner(uint256 tokenId);
    error NothingToDo();
    error Frozen();
    error TransferFailed();

    constructor() ERC721("", "") Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @dev Royalties (split on the next mint or `processPending`), WETH unwraps and swap outputs.
    receive() external payable {}

    /// @notice Called once by the factory right after cloning. The factory checks the routes.
    function initialize(InitParams calldata p, address creator, bool isOfficial) external initializer {
        Economy calldata e = p.economy;
        if (
            uint256(e.creatorBps) + e.holdersBps + e.burnBps != BPS || p.royaltyBps > MAX_ROYALTY_BPS
                || (p.kind == Kind.Unique && p.maxSupply == 0) || (p.mintEnd != 0 && p.mintEnd <= p.mintStart)
                || (p.token == ETH && (p.mintPrice != 0 || e.burnBps != 0 || p.rewardToken != ETH))
                || (p.tokenPayments && p.mintPrice == 0) || bytes(p.name).length == 0 || creator == address(0)
        ) revert InvalidConfig();
        factory = msg.sender;
        _transferOwnership(creator);
        _name = p.name;
        _symbol = p.symbol;
        kind = p.kind;
        _baseURIValue = p.baseURI;
        uriSuffix = p.uriSuffix;
        contractURI = p.contractURI;
        maxSupply = p.maxSupply;
        maxPerWallet = p.maxPerWallet;
        mintStart = p.mintStart;
        mintEnd = p.mintEnd;
        mintPrice = p.mintPrice;
        token = p.token;
        tokenPayments = p.tokenPayments;
        rewardToken = p.rewardToken;
        royaltyBps = p.royaltyBps;
        _economy = e;
        _launchPool = p.launchPool;
        official = isOfficial;
        emit CollectionInitialized(creator, p.token, p.rewardToken, isOfficial, p.kind);
    }

    // ───────────────────────────── Mint ─────────────────────────────

    /// @notice Mints `quantity` NFTs to `to`, paying `mintPrice` each in ETH.
    function mint(address to, uint256 quantity) external payable nonReentrant returns (uint256 firstTokenId) {
        uint256 cost = uint256(mintPrice) * quantity;
        if (msg.value != cost) revert WrongPayment(msg.value, cost);
        firstTokenId = _settleMint(to, quantity, ETH, cost);
    }

    /// @notice Mints `quantity` NFTs to `to`, paying in the pair token the market equivalent of the ETH price:
    ///         the larger of the reference and the spot amounts of PlacePriceGuard (reverts while the price is not
    ///         ready or deviates). `maxTokenIn` caps what the buyer pays.
    function mintWithToken(address to, uint256 quantity, uint256 maxTokenIn)
        external
        nonReentrant
        returns (uint256 firstTokenId, uint256 paid)
    {
        if (!tokenPayments) revert TokenPaymentsDisabled();
        address t = token;
        uint256 due = quoteTokenPrice(quantity);
        if (due > maxTokenIn) revert TokenAmountAboveMax(due, maxTokenIn);
        // After the quote: an observation never counts in its own block.
        _swapper().observeMint(address(this));
        uint256 before = IERC20(t).balanceOf(address(this));
        IERC20(t).safeTransferFrom(msg.sender, address(this), due);
        paid = IERC20(t).balanceOf(address(this)) - before;
        firstTokenId = _settleMint(to, quantity, t, paid);
    }

    // ───────────────────────────── Holders ─────────────────────────────

    /// @notice Settles the caller's NFTs `tokenIds` and pays everything credited to the caller in the reward token
    ///         (also what NFTs it sold had accrued; pass no ids for that alone).
    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 amount) {
        _accrue();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            if (ownerOf(id) != msg.sender) revert NotTokenOwner(id);
            _settle(id, msg.sender);
        }
        amount = credit[msg.sender];
        if (amount != 0) {
            credit[msg.sender] = 0;
            _pay(rewardToken, msg.sender, amount);
            emit HoldersClaimed(msg.sender, amount);
        }
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Splits royalties that reached the contract in `asset` and retries every waiting swap (holders
    ///         shares into the reward token, ETH into burned pair tokens; a failed swap keeps waiting). ETH and
    ///         WETH (unwrapped) and the pair token join the economy; any other ERC-20 goes 20% to the platform and
    ///         the rest to the creator (`payOut`). Anyone can call it, also with nothing to split.
    function processPending(address asset) external nonReentrant returns (uint256 amount) {
        _accrue();
        address weth = IPlaceNftFactory(factory).weth();
        if (asset == weth && weth != address(0)) {
            uint256 wrapped = IERC20(weth).balanceOf(address(this));
            if (wrapped != 0) IWETH9(weth).withdraw(wrapped);
            asset = ETH;
        }
        if (asset == ETH) {
            amount = _splitEthRoyalties(0, totalMinted);
        } else {
            amount = IERC20(asset).balanceOf(address(this)) - reserved[asset];
            if (asset == token) {
                if (amount != 0) _split(asset, amount, true, totalMinted);
            } else {
                uint256 platform = amount * PLATFORM_BPS / BPS;
                platformOwed[asset] += platform;
                creatorOwed[asset] += amount - platform;
                reserved[asset] += amount;
                emit RevenueSplit(asset, platform, amount - platform, 0, 0, true);
            }
        }
        _processPending();
    }

    /// @notice Buys and burns the pair token with up to `maxEthIn` of the waiting buyback ETH (a slice, when the
    ///         whole amount would move the pool too much). Reverts if the guarded swap cannot run.
    function buyback(uint256 maxEthIn) external nonReentrant returns (uint256 burned) {
        uint256 amountIn = Math.min(maxEthIn, buybackPending);
        if (amountIn == 0) revert NothingToDo();
        burned = _swap(ETH, amountIn, true);
    }

    /// @notice Pays what the creator (the collection owner) and the platform (the factory's recipient) are owed in
    ///         `asset`. Anyone can call it.
    function payOut(address asset) external nonReentrant returns (uint256 creatorAmount, uint256 platformAmount) {
        creatorAmount = creatorOwed[asset];
        platformAmount = platformOwed[asset];
        if (creatorAmount + platformAmount == 0) revert NothingToDo();
        creatorOwed[asset] = 0;
        platformOwed[asset] = 0;
        address creator = owner();
        address platform = _platform();
        emit Paid(creator, platform, asset, creatorAmount, platformAmount);
        if (creatorAmount != 0) {
            if (asset == ETH) {
                // A creator that refuses ETH keeps its share owed instead of blocking the platform payout.
                (bool ok,) = creator.call{value: creatorAmount}("");
                if (ok) reserved[ETH] -= creatorAmount;
                else creatorOwed[ETH] = creatorAmount;
            } else {
                _pay(asset, creator, creatorAmount);
            }
        }
        if (platformAmount != 0) _pay(asset, platform, platformAmount);
    }

    // ───────────────────────────── Creator ─────────────────────────────

    /// @notice Mint settings: price per NFT in ETH (0 = free; needs a pair token otherwise), window (`end` 0 = no
    ///         end) and whether the pair token is also accepted.
    function setMint(uint128 price, uint64 start, uint64 end, bool payInToken) external onlyOwner {
        if ((end != 0 && end <= start) || (price == 0 && payInToken) || (price != 0 && token == ETH)) {
            revert InvalidConfig();
        }
        (mintPrice, mintStart, mintEnd, tokenPayments) = (price, start, end, payInToken);
        emit MintSet(price, start, end, payInToken);
    }

    function setRoyaltyBps(uint16 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert InvalidConfig();
        royaltyBps = bps;
        emit RoyaltySet(bps);
    }

    function setBaseURI(string calldata newBaseURI, string calldata newSuffix) external onlyOwner {
        if (metadataFrozen) revert Frozen();
        _baseURIValue = newBaseURI;
        uriSuffix = newSuffix;
        emit BaseURISet(newBaseURI, newSuffix);
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    function setContractURI(string calldata newContractURI) external onlyOwner {
        contractURI = newContractURI;
        emit ContractURIUpdated();
    }

    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @notice Disabled: a collection always has an owner that receives the creator share.
    function renounceOwnership() public view override onlyOwner {
        revert InvalidConfig();
    }

    // ───────────────────────────── Views ─────────────────────────────

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function baseURI() external view returns (string memory) {
        return _baseURIValue;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (kind == Kind.Edition) return _baseURIValue;
        return string.concat(_baseURIValue, tokenId.toString(), uriSuffix);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function economy() external view returns (Economy memory) {
        return _economy;
    }

    function launchPool() external view returns (PoolKey memory) {
        return _launchPool;
    }

    /// @notice ERC-2981: royalties are paid to this contract and split like the mint.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        return (address(this), salePrice * royaltyBps / BPS);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == bytes4(0x49064906)
            || super.supportsInterface(interfaceId);
    }

    /// @notice Reward token NFT `tokenId` has accrued and not settled, as of now.
    function claimable(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        (uint256 acc,) = _accrued();
        return (acc - _paid[tokenId]) / ACC;
    }

    /// @notice Pair-token amount `mintWithToken` would charge for `quantity` NFTs now.
    function quoteTokenPrice(uint256 quantity) public view returns (uint256 due) {
        (uint256 referenceOut, uint256 spotOut) = _swapper().quoteMint(address(this), uint256(mintPrice) * quantity);
        due = Math.max(referenceOut, spotOut);
        if (due == 0) revert InvalidConfig();
    }

    // ───────────────────────────── Internals ─────────────────────────────

    /// @dev Accrues the pool, splits royalties and the payment (holders share to the creator if no NFT exists yet),
    ///      runs the waiting swaps, then mints.
    function _settleMint(address to, uint256 quantity, address asset, uint256 paid) internal returns (uint256 first) {
        _accrue();
        uint256 holdersBefore = totalMinted;
        _splitEthRoyalties(asset == ETH ? paid : 0, holdersBefore);
        if (paid != 0) _split(asset, paid, false, holdersBefore);
        _processPending();
        first = _mintMany(to, quantity);
        emit Minted(to, first, quantity, asset, paid);
    }

    function _swapper() internal view returns (IPlaceNftSwapper) {
        return IPlaceNftSwapper(IPlaceNftFactory(factory).swapper());
    }

    function _platform() internal view returns (address) {
        return IPlaceNftFactory(factory).platformRecipient();
    }

    function _mintMany(address to, uint256 quantity) internal returns (uint256 first) {
        // forge-lint: disable-next-line(block-timestamp) mint window in minutes or days
        if (block.timestamp < mintStart || (mintEnd != 0 && block.timestamp >= mintEnd)) revert MintClosed();
        if (quantity == 0) revert InvalidConfig();
        uint256 minted = totalMinted;
        if ((maxSupply != 0 && minted + quantity > maxSupply) || minted + quantity > type(uint32).max) {
            revert SoldOut();
        }
        uint256 walletMinted = uint256(mintedBy[to]) + quantity;
        if (maxPerWallet != 0 && walletMinted > maxPerWallet) revert WalletLimit();
        // forge-lint: disable-next-line(unsafe-typecast) bounded by maxSupply or by the uint32 check above
        mintedBy[to] = uint32(walletMinted);
        // forge-lint: disable-next-line(unsafe-typecast) checked above
        totalMinted = uint32(minted + quantity);
        first = minted + 1;
        for (uint256 id = first; id < first + quantity; id++) {
            _safeMint(to, id);
        }
    }

    /// @dev New NFTs start from the current accumulator; a transfer settles the NFT for its previous owner.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        _accrue();
        from = _ownerOf(tokenId);
        if (from == address(0)) {
            _paid[tokenId] = accPerNft;
        } else if (to != from) {
            _settle(tokenId, from);
        }
        return super._update(to, tokenId, auth);
    }

    /// @dev Credits NFT `id`'s accrued rewards to `account` (the pool must be accrued).
    function _settle(uint256 id, address account) internal {
        uint256 acc = accPerNft;
        credit[account] += (acc - _paid[id]) / ACC;
        _paid[id] = acc;
    }

    /// @dev The accumulator after the daily portions of every whole UTC day since the last accrual, and today.
    function _accrued() internal view returns (uint256 acc, uint64 today) {
        // forge-lint: disable-next-line(unsafe-typecast) days fit in uint64
        today = uint64(block.timestamp / 1 days);
        acc = accPerNft;
        uint256 end = Math.min(today, periodFinish);
        uint256 last = lastAccrualDay;
        uint256 supply = totalMinted;
        if (end > last && supply != 0) acc += rewardRate * (end - last) / supply;
    }

    function _accrue() internal {
        (uint256 acc, uint64 today) = _accrued();
        if (today == lastAccrualDay) return;
        accPerNft = acc;
        lastAccrualDay = today;
    }

    /// @dev Adds `amount` of the reward token (already in `reserved`) to the holders pool: what is left of the
    ///      current pool plus `amount` is paid over the next `POOL_DAYS` days, from tomorrow 00:00 UTC.
    function _fundPool(uint256 amount) internal {
        _accrue();
        uint64 today = lastAccrualDay;
        uint256 left = periodFinish > today ? rewardRate * (periodFinish - today) : 0;
        uint256 rate = (amount * ACC + left) / POOL_DAYS;
        uint64 finish = today + uint64(POOL_DAYS);
        (rewardRate, periodFinish) = (rate, finish);
        emit HoldersFunded(amount, rate, finish);
    }

    /// @dev Splits ETH above what the contract owes (royalties), leaving `excluded` (this mint's payment) aside.
    function _splitEthRoyalties(uint256 excluded, uint256 holders) internal returns (uint256 amount) {
        uint256 owed = reserved[ETH] + excluded;
        uint256 balance = address(this).balance;
        if (balance <= owed) return 0;
        amount = balance - owed;
        _split(ETH, amount, true, holders);
    }

    /// @dev Splits `amount` of `asset` (ETH or the pair token) the contract holds. `holders`: the NFT count; with
    ///      none the holders share goes to the creator.
    function _split(address asset, uint256 amount, bool royalty, uint256 holders) internal {
        Economy memory e = _economy;
        uint256 platform = amount * PLATFORM_BPS / BPS;
        uint256 rest = amount - platform;
        uint256 toBurn = rest * e.burnBps / BPS;
        uint256 toHolders = holders == 0 ? 0 : rest * e.holdersBps / BPS;
        uint256 toCreator = rest - toBurn - toHolders;
        platformOwed[asset] += platform;
        creatorOwed[asset] += toCreator;
        reserved[asset] += platform + toCreator + toHolders;
        if (toHolders != 0) {
            if (asset == rewardToken) _fundPool(toHolders);
            else pendingHolders[asset] += toHolders;
        }
        if (toBurn != 0) {
            if (asset == ETH) {
                buybackPending += toBurn;
                reserved[ETH] += toBurn;
            } else {
                _burnTokens(toBurn, 0);
            }
        }
        emit RevenueSplit(asset, platform, toCreator, toHolders, toBurn, royalty);
    }

    /// @dev Tries every waiting swap; a swap that cannot run safely leaves its amount waiting.
    function _processPending() internal {
        if (IPlaceNftFactory(factory).swapper().code.length == 0) return;
        _tryConvert(ETH);
        if (token != ETH) _tryConvert(token);
        uint256 burnIn = buybackPending;
        if (burnIn != 0) {
            try this.swapFromSelf(ETH, burnIn, true) {}
            catch {
                emit ConversionDeferred(BURN_SINK, burnIn);
            }
        }
    }

    function _tryConvert(address asset) internal {
        uint256 amountIn = pendingHolders[asset];
        if (amountIn == 0 || asset == rewardToken) return;
        try this.swapFromSelf(asset, amountIn, false) returns (uint256 out) {
            pendingHolders[asset] = 0;
            emit HoldersConverted(asset, amountIn, out);
            _fundPool(out);
        } catch {
            emit ConversionDeferred(asset, amountIn);
        }
    }

    /// @dev Only callable by the contract itself, so that a failing swap reverts alone inside `try`.
    function swapFromSelf(address input, uint256 amountIn, bool burn) external returns (uint256) {
        if (msg.sender != address(this)) revert NothingToDo();
        return _swap(input, amountIn, burn);
    }

    /// @dev Guarded swap of `amountIn` of `input`: ETH into burned pair tokens (`burn`), or a waiting holders share
    ///      into the reward token.
    function _swap(address input, uint256 amountIn, bool burn) internal returns (uint256 out) {
        IPlaceNftSwapper swapper = _swapper();
        address output = burn ? token : rewardToken;
        uint256 before = _balance(output);
        if (input == ETH) {
            swapper.swapFor{value: amountIn}(ETH, amountIn, burn);
        } else {
            IERC20(input).forceApprove(address(swapper), amountIn);
            swapper.swapFor(input, amountIn, burn);
        }
        out = _balance(output) - before;
        reserved[input] -= amountIn;
        if (burn) {
            buybackPending -= amountIn;
            _burnTokens(out, amountIn);
        } else {
            reserved[output] += out;
        }
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == ETH ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _burnTokens(uint256 amount, uint256 ethIn) internal {
        totalBurned += amount;
        IERC20(token).safeTransfer(BURN_SINK, amount);
        emit TokensBurned(amount, ethIn);
    }

    /// @dev Pays an amount that `reserved` covers.
    function _pay(address asset, address to, uint256 amount) internal {
        reserved[asset] -= amount;
        if (asset == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
