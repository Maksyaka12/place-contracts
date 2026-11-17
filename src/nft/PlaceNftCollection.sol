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
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceRouteSwapper} from "../place/PlaceRouteSwapper.sol";
import {IPlaceRewardTokenRegistry} from "../place/interfaces/IPlaceRewardTokenRegistry.sol";
import {IPlaceNftFactory, IPlacePriceGuard} from "./interfaces/IPlaceNft.sol";

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

/// @title PlaceNftCollection
/// @notice An ERC-721 collection of the Place NFT launchpad (a clone per collection, made by PlaceNftFactory).
///
///         - **Kinds**: Unique (one metadata file per token: `baseURI + id + uriSuffix`, an IPFS folder) or Edition
///           (one metadata URI for every token).
///         - **Mint**: always in ETH at a fixed price; optionally also in the linked token, at the market equivalent
///           of the ETH price at the moment of the mint (PlacePriceGuard: manipulation-resistant reference price,
///           the buyer pays the larger of the reference and spot amounts).
///         - **Economy** of every payment and of every royalty that reaches the contract (ERC-2981, 0–10%): 20% to
///           the platform, the rest split as the creator set at creation (immutable): creator / NFT holders /
///           buyback & burn of the linked token.
///           * Holders: credited per NFT (on-chain accumulator); the owner of an NFT claims what it earned.
///           * Burn: payments in the token are burned at once (sent to 0x…dEaD); the ETH part waits in the
///             contract and anyone calls `buyback` to buy the token through its Uniswap v4 pool (route from the
///             PlaceRewardTokenRegistry or the token's Place launch pool), capped by the registry's price impact
///             per hop and by the guard's reference price, then burns it.
///         - Royalties in ETH or WETH join the ETH economy; in the linked token they join the token economy; in
///           any other ERC-20 the platform takes 20% and the creator the rest (no holders accumulator or route).
/// @dev    `reserved[asset]` is what the contract owes (creator, platform, holders, pending buyback); everything
///         above it is an unprocessed royalty that `distributeRoyalties` splits.
contract PlaceNftCollection is ERC721, IERC2981, Ownable2Step, Initializable, ReentrancyGuard, PlaceRouteSwapper {
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
        uint128 mintPrice; // wei per NFT; 0 = free mint (no economy, no token payments)
        address token; // the linked token (0 = none: no burn share, no token payments)
        bool tokenPayments; // also accept the linked token at the ETH-equivalent price
        uint16 royaltyBps; // 0–1 000
        Economy economy;
        PoolKey launchPool; // the token's Place launch pool (tickSpacing 0 = none; verified by the factory)
    }

    uint16 public constant PLATFORM_BPS = 2_000;
    uint16 public constant MAX_ROYALTY_BPS = 1_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ACC = 1e36;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    address internal constant ETH = address(0);

    address public factory;
    IPoolManager public poolManager;
    address public token;
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
    /// @notice ETH waiting to buy back and burn the linked token.
    uint256 public buybackPending;
    /// @notice Holders accumulator: rewards per NFT since the first mint, scaled by 1e36 (ETH and the token).
    mapping(address asset => uint256 perNft) public accPerNft;
    mapping(uint256 tokenId => mapping(address asset => uint256 perNft)) internal _paidPerNft;
    /// @notice Lifetime totals for the collection page.
    mapping(address asset => uint256 amount) public totalBurned;

    event CollectionInitialized(address indexed creator, address indexed token, bool official, Kind kind);
    event Minted(address indexed to, uint256 firstTokenId, uint256 quantity, address indexed asset, uint256 paid);
    event RevenueSplit(
        address indexed asset, uint256 platform, uint256 creator, uint256 holders, uint256 burn, bool royalty
    );
    event HoldersClaimed(address indexed owner, uint256 ethAmount, uint256 tokenAmount);
    event CreatorPaid(address indexed to, address indexed asset, uint256 amount);
    event PlatformPaid(address indexed to, address indexed asset, uint256 amount);
    event TokensBurned(uint256 amount, bool fromBuyback);
    event BuybackExecuted(address indexed caller, uint256 ethIn, uint256 tokensBurned);
    event MintPriceSet(uint128 price);
    event MintWindowSet(uint64 start, uint64 end);
    event TokenPaymentsSet(bool enabled);
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
    error NoRoute();
    error NothingToDo();
    error BuybackSlippage(uint256 out, uint256 minOut);
    error UnsupportedAsset();
    error Frozen();
    error TransferFailed();

    constructor() ERC721("", "") Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @dev Royalties and WETH unwraps; split later by `distributeRoyalties`.
    receive() external payable {}

    /// @notice Called once by the factory right after cloning.
    function initialize(InitParams calldata p, address creator, bool isOfficial, IPoolManager manager)
        external
        initializer
    {
        Economy calldata e = p.economy;
        if (
            uint256(e.creatorBps) + e.holdersBps + e.burnBps != BPS || p.royaltyBps > MAX_ROYALTY_BPS
                || (p.kind == Kind.Unique && p.maxSupply == 0) || (p.mintEnd != 0 && p.mintEnd <= p.mintStart)
                || (p.token == ETH && (e.burnBps != 0 || p.tokenPayments)) || (p.tokenPayments && p.mintPrice == 0)
                || bytes(p.name).length == 0 || creator == address(0)
        ) revert InvalidConfig();
        factory = msg.sender;
        poolManager = manager;
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
        royaltyBps = p.royaltyBps;
        _economy = e;
        _launchPool = p.launchPool;
        official = isOfficial;
        emit CollectionInitialized(creator, p.token, isOfficial, p.kind);
    }

    // ───────────────────────────── Mint ─────────────────────────────

    /// @notice Mints `quantity` NFTs to `to`, paying `mintPrice` each in ETH.
    function mint(address to, uint256 quantity) external payable nonReentrant returns (uint256 firstTokenId) {
        uint256 cost = uint256(mintPrice) * quantity;
        if (msg.value != cost) revert WrongPayment(msg.value, cost);
        firstTokenId = _mintMany(to, quantity);
        emit Minted(to, firstTokenId, quantity, ETH, cost);
        if (cost != 0) _split(ETH, cost, false);
    }

    /// @notice Mints `quantity` NFTs to `to`, paying in the linked token the market equivalent of the ETH price:
    ///         the larger of the reference and the spot amounts of PlacePriceGuard (reverts while the pool's price
    ///         is not ready or deviates). `maxTokenIn` caps what the buyer pays.
    function mintWithToken(address to, uint256 quantity, uint256 maxTokenIn)
        external
        nonReentrant
        returns (uint256 firstTokenId, uint256 paid)
    {
        if (!tokenPayments) revert TokenPaymentsDisabled();
        uint256 due = quoteTokenPrice(quantity);
        if (due > maxTokenIn) revert TokenAmountAboveMax(due, maxTokenIn);
        _guard().observeRoute(ethRoute()); // after the quote: an observation never counts in its own block
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), due);
        paid = IERC20(token).balanceOf(address(this)) - before;
        firstTokenId = _mintMany(to, quantity);
        emit Minted(to, firstTokenId, quantity, token, paid);
        _split(token, paid, false);
    }

    // ───────────────────────────── Holders ─────────────────────────────

    /// @notice Pays the caller what its NFTs `tokenIds` earned, in ETH and in the linked token.
    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 ethAmount, uint256 tokenAmount) {
        address t = token;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            if (ownerOf(id) != msg.sender) revert NotTokenOwner(id);
            ethAmount += _settle(id, ETH);
            if (t != ETH) tokenAmount += _settle(id, t);
        }
        if (ethAmount != 0) {
            reserved[ETH] -= ethAmount;
            _sendETH(msg.sender, ethAmount);
        }
        if (tokenAmount != 0) {
            reserved[t] -= tokenAmount;
            IERC20(t).safeTransfer(msg.sender, tokenAmount);
        }
        emit HoldersClaimed(msg.sender, ethAmount, tokenAmount);
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Splits royalties that reached the contract: ETH (WETH is unwrapped first), the linked token, or
    ///         any other ERC-20 (20% platform, the rest to the creator).
    function distributeRoyalties(address asset) external nonReentrant returns (uint256 amount) {
        address weth = IPlaceNftFactory(factory).weth();
        if (asset == weth && weth != address(0)) {
            uint256 wrapped = IERC20(weth).balanceOf(address(this));
            if (wrapped != 0) IWETH9(weth).withdraw(wrapped);
            asset = ETH;
        }
        uint256 balance = asset == ETH ? address(this).balance : IERC20(asset).balanceOf(address(this));
        amount = balance - reserved[asset];
        if (amount == 0) revert NothingToDo();
        if (asset == ETH || asset == token) {
            _split(asset, amount, true);
        } else {
            uint256 platform = amount * PLATFORM_BPS / BPS;
            emit RevenueSplit(asset, platform, amount - platform, 0, 0, true);
            IERC20(asset).safeTransfer(_platform(), platform);
            IERC20(asset).safeTransfer(owner(), amount - platform);
        }
    }

    /// @notice Buys the linked token with up to `maxEthIn` of the pending buyback ETH and burns it. Anyone can
    ///         call it. Each hop may move its pool by at most the registry's `maxPriceImpactBps`, and the output
    ///         must reach the guard's reference output minus (max deviation + impact), so a sandwich reverts it.
    function buyback(uint256 maxEthIn) external nonReentrant returns (uint256 burned) {
        uint256 amountIn = maxEthIn < buybackPending ? maxEthIn : buybackPending;
        if (amountIn == 0) revert NothingToDo();
        PoolKey[] memory route = ethRoute();
        IPlacePriceGuard guard = _guard();
        (uint256 referenceOut,) = guard.quote(route, ETH, amountIn);
        guard.observeRoute(route);
        uint16 impact = IPlaceRewardTokenRegistry(_registry()).maxPriceImpactBps();
        uint256 tolerance = uint256(guard.config().maxDeviationBps) + uint256(impact) * route.length;
        uint256 minOut = tolerance >= BPS ? 0 : referenceOut * (BPS - tolerance) / BPS;
        buybackPending -= amountIn;
        reserved[ETH] -= amountIn;
        (, burned) = _swapRoute(ETH, route, amountIn, impact);
        if (burned < minOut) revert BuybackSlippage(burned, minOut);
        _burnTokens(burned, true);
        emit BuybackExecuted(msg.sender, amountIn, burned);
    }

    /// @notice Pays the creator (the collection owner) what it is owed in `asset`.
    function payCreator(address asset) external nonReentrant returns (uint256 amount) {
        amount = creatorOwed[asset];
        if (amount == 0) revert NothingToDo();
        creatorOwed[asset] = 0;
        reserved[asset] -= amount;
        address to = owner();
        _send(asset, to, amount);
        emit CreatorPaid(to, asset, amount);
    }

    /// @notice Pays the platform share in `asset` to the factory's platform recipient.
    function payPlatform(address asset) external nonReentrant returns (uint256 amount) {
        amount = platformOwed[asset];
        if (amount == 0) revert NothingToDo();
        platformOwed[asset] = 0;
        reserved[asset] -= amount;
        address to = _platform();
        _send(asset, to, amount);
        emit PlatformPaid(to, asset, amount);
    }

    // ───────────────────────────── Creator ─────────────────────────────

    function setMintPrice(uint128 price) external onlyOwner {
        if (price == 0 && tokenPayments) revert InvalidConfig();
        mintPrice = price;
        emit MintPriceSet(price);
    }

    function setMintWindow(uint64 start, uint64 end) external onlyOwner {
        if (end != 0 && end <= start) revert InvalidConfig();
        mintStart = start;
        mintEnd = end;
        emit MintWindowSet(start, end);
    }

    function setTokenPayments(bool enabled) external onlyOwner {
        if (enabled && (token == ETH || mintPrice == 0)) revert InvalidConfig();
        tokenPayments = enabled;
        emit TokenPaymentsSet(enabled);
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

    /// @notice What NFT `tokenId` has earned and not claimed: ETH and the linked token.
    function claimable(uint256 tokenId) external view returns (uint256 ethAmount, uint256 tokenAmount) {
        _requireOwned(tokenId);
        ethAmount = (accPerNft[ETH] - _paidPerNft[tokenId][ETH]) / ACC;
        if (token != ETH) tokenAmount = (accPerNft[token] - _paidPerNft[tokenId][token]) / ACC;
    }

    /// @notice Token amount `mintWithToken` would charge for `quantity` NFTs now.
    function quoteTokenPrice(uint256 quantity) public view returns (uint256 due) {
        (uint256 referenceOut, uint256 spotOut) = _guard().quote(ethRoute(), ETH, uint256(mintPrice) * quantity);
        due = referenceOut > spotOut ? referenceOut : spotOut;
        if (due == 0) revert NoRoute();
    }

    /// @notice The ETH -> token route: the token's Place launch pool (behind a registry route ETH -> its quote if
    ///         the quote is not ETH), or else the registry route ETH -> token.
    function ethRoute() public view returns (PoolKey[] memory route) {
        if (token == ETH) revert NoRoute();
        IPlaceRewardTokenRegistry registry = IPlaceRewardTokenRegistry(_registry());
        PoolKey memory pool = _launchPool;
        if (pool.tickSpacing == 0) {
            route = address(registry) == address(0) ? new PoolKey[](0) : registry.routeOf(ETH, token);
        } else {
            address c0 = Currency.unwrap(pool.currency0);
            address quoteAsset = c0 == token ? Currency.unwrap(pool.currency1) : c0;
            PoolKey[] memory head;
            if (quoteAsset != ETH) {
                if (address(registry) == address(0)) revert NoRoute();
                head = registry.routeOf(ETH, quoteAsset);
                if (head.length == 0) revert NoRoute();
            }
            route = new PoolKey[](head.length + 1);
            for (uint256 i = 0; i < head.length; i++) {
                route[i] = head[i];
            }
            route[head.length] = pool;
        }
        if (route.length == 0) revert NoRoute();
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function _guard() internal view returns (IPlacePriceGuard guard) {
        guard = IPlacePriceGuard(IPlaceNftFactory(factory).priceGuard());
        if (address(guard) == address(0)) revert NoRoute();
    }

    function _registry() internal view returns (address) {
        return IPlaceNftFactory(factory).rewardRegistry();
    }

    function _platform() internal view returns (address) {
        return IPlaceNftFactory(factory).platformRecipient();
    }

    function _mintMany(address to, uint256 quantity) internal returns (uint256 first) {
        // forge-lint: disable-next-line(block-timestamp) mint window in minutes or days
        if (block.timestamp < mintStart || (mintEnd != 0 && block.timestamp >= mintEnd)) revert MintClosed();
        if (quantity == 0) revert InvalidConfig();
        uint256 minted = totalMinted;
        if (maxSupply != 0 && minted + quantity > maxSupply) revert SoldOut();
        uint256 walletMinted = uint256(mintedBy[to]) + quantity;
        if (maxPerWallet != 0 && walletMinted > maxPerWallet) revert WalletLimit();
        // forge-lint: disable-next-line(unsafe-typecast) bounded by maxSupply or by the uint32 check below
        mintedBy[to] = uint32(walletMinted);
        if (minted + quantity > type(uint32).max) revert SoldOut();
        // forge-lint: disable-next-line(unsafe-typecast) checked above
        totalMinted = uint32(minted + quantity);
        first = minted + 1;
        uint256 accEth = accPerNft[ETH];
        address t = token;
        uint256 accToken = t == ETH ? 0 : accPerNft[t];
        for (uint256 id = first; id < first + quantity; id++) {
            // New NFTs start from the current accumulator: they earn only what comes after them.
            if (accEth != 0) _paidPerNft[id][ETH] = accEth;
            if (accToken != 0) _paidPerNft[id][t] = accToken;
            _safeMint(to, id);
        }
    }

    /// @dev Splits `amount` of `asset` (ETH or the linked token) that the contract already holds.
    function _split(address asset, uint256 amount, bool royalty) internal {
        Economy memory e = _economy;
        uint256 platform = amount * PLATFORM_BPS / BPS;
        uint256 rest = amount - platform;
        uint256 toBurn = rest * e.burnBps / BPS;
        uint256 toHolders = rest * e.holdersBps / BPS;
        uint256 supply = totalMinted;
        if (supply == 0) toHolders = 0; // no NFT yet (royalty before any mint): the creator takes it
        uint256 toCreator = rest - toBurn - toHolders;
        platformOwed[asset] += platform;
        creatorOwed[asset] += toCreator;
        reserved[asset] += platform + toCreator + toHolders;
        if (toHolders != 0) accPerNft[asset] += toHolders * ACC / supply;
        if (toBurn != 0) {
            if (asset == ETH) {
                buybackPending += toBurn;
                reserved[ETH] += toBurn;
            } else {
                _burnTokens(toBurn, false);
            }
        }
        emit RevenueSplit(asset, platform, toCreator, toHolders, toBurn, royalty);
    }

    function _settle(uint256 tokenId, address asset) internal returns (uint256 amount) {
        uint256 acc = accPerNft[asset];
        amount = (acc - _paidPerNft[tokenId][asset]) / ACC;
        if (amount != 0) _paidPerNft[tokenId][asset] = acc;
    }

    function _burnTokens(uint256 amount, bool fromBuyback) internal {
        totalBurned[token] += amount;
        IERC20(token).safeTransfer(BURN_SINK, amount);
        emit TokensBurned(amount, fromBuyback);
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (asset == ETH) _sendETH(to, amount);
        else IERC20(asset).safeTransfer(to, amount);
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
