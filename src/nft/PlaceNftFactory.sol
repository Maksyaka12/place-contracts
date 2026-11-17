// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceNftCollection} from "./PlaceNftCollection.sol";

/// @notice The launch-factory views used to find a Place token's creator and launch pool.
interface IPlaceLaunchFactoryViews {
    struct CreatorRights {
        address originalCreator;
        address currentCreator;
        address pendingCreator;
        address creatorFeeRecipient;
        PoolId poolId;
        bool metadataEditable;
    }

    function hook() external view returns (address);
    function creatorRights(address token) external view returns (CreatorRights memory);
}

/// @notice A registry of external (non-Place) tokens whose creator proved ownership ("Register token").
interface IPlaceProjectRegistry {
    function creatorOf(address token) external view returns (address);
}

interface IOwnable {
    function owner() external view returns (address);
}

/// @title PlaceNftFactory
/// @notice Creates PlaceNftCollection clones. Anyone can create a collection for any token (or none). A collection
///         is **official** when its creator is the creator of the linked token at creation:
///         - Place tokens: the current creator in a listed Place launch factory;
///         - other tokens: the creator in the project registry (if set), else the token's `owner()`.
///         Owner (the platform): the creation fee, the platform recipient, the reward-token registry (swap routes),
///         the price guard, the launch factories and the collection template of new collections.
contract PlaceNftFactory is Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    uint256 public constant MAX_CREATION_FEE = 0.05 ether;

    IPoolManager public immutable poolManager;
    address public implementation;
    address public platformRecipient;
    address public rewardRegistry;
    address public priceGuard;
    address public weth;
    address public projectRegistry;
    uint256 public creationFee;

    address[] internal _launchFactories;
    address[] internal _collections;
    mapping(address collection => bool) public isCollection;
    mapping(address token => address[] collections) internal _collectionsOf;

    event CollectionCreated(
        address indexed collection,
        address indexed creator,
        address indexed token,
        bool official,
        PlaceNftCollection.Kind kind,
        uint256 index
    );
    event ImplementationSet(address implementation);
    event PlatformRecipientSet(address recipient);
    event RewardRegistrySet(address registry);
    event PriceGuardSet(address guard);
    event WethSet(address weth);
    event ProjectRegistrySet(address registry);
    event CreationFeeSet(uint256 fee);
    event LaunchFactoryAdded(address factory);
    event LaunchFactoryRemoved(address factory);

    error InvalidConfig();
    error WrongFee(uint256 sent, uint256 expected);
    error InvalidLaunchPool();
    error FeeTransferFailed();

    struct Settings {
        address implementation;
        address platformRecipient;
        address rewardRegistry;
        address priceGuard;
        address weth;
        uint256 creationFee;
    }

    constructor(IPoolManager manager, address initialOwner, Settings memory s) Ownable(initialOwner) {
        if (address(manager) == address(0)) revert InvalidConfig();
        poolManager = manager;
        _setImplementation(s.implementation);
        _setPlatformRecipient(s.platformRecipient);
        _setCreationFee(s.creationFee);
        rewardRegistry = s.rewardRegistry;
        priceGuard = s.priceGuard;
        weth = s.weth;
    }

    /// @notice Creates a collection owned by the caller. `p.launchPool` (optional) must be the Place launch pool of
    ///         `p.token`; it lets the collection buy back and price the token without a registry route.
    function createCollection(PlaceNftCollection.InitParams calldata p)
        external
        payable
        nonReentrant
        returns (address collection)
    {
        if (msg.value != creationFee) revert WrongFee(msg.value, creationFee);
        if (p.launchPool.tickSpacing != 0 && !isLaunchPool(p.token, p.launchPool)) revert InvalidLaunchPool();
        bool official = isTokenCreator(p.token, msg.sender);
        collection = Clones.clone(implementation);
        PlaceNftCollection(payable(collection)).initialize(p, msg.sender, official, poolManager);
        isCollection[collection] = true;
        _collections.push(collection);
        if (p.token != address(0)) _collectionsOf[p.token].push(collection);
        emit CollectionCreated(collection, msg.sender, p.token, official, p.kind, _collections.length - 1);
        if (msg.value != 0) {
            (bool ok,) = platformRecipient.call{value: msg.value}("");
            if (!ok) revert FeeTransferFailed();
        }
    }

    // ───────────────────────────── Views ─────────────────────────────

    /// @notice Whether `account` is the creator of `token` (see the contract notice).
    function isTokenCreator(address token, address account) public view returns (bool) {
        if (token == address(0) || token.code.length == 0) return false;
        for (uint256 i = 0; i < _launchFactories.length; i++) {
            try IPlaceLaunchFactoryViews(_launchFactories[i]).creatorRights(token) returns (
                IPlaceLaunchFactoryViews.CreatorRights memory rights
            ) {
                return rights.currentCreator == account;
            } catch {}
        }
        if (projectRegistry != address(0)) {
            try IPlaceProjectRegistry(projectRegistry).creatorOf(token) returns (address creator) {
                if (creator != address(0)) return creator == account;
            } catch {}
        }
        // Low-level: a token without owner() (or with a fallback) must not revert the whole call.
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IOwnable.owner, ()));
        if (!ok || data.length != 32) return false;
        address tokenOwner = abi.decode(data, (address));
        return tokenOwner != address(0) && tokenOwner == account;
    }

    /// @notice Whether `key` is the launch pool of Place token `token` in a listed launch factory.
    function isLaunchPool(address token, PoolKey calldata key) public view returns (bool) {
        if (Currency.unwrap(key.currency0) != token && Currency.unwrap(key.currency1) != token) return false;
        for (uint256 i = 0; i < _launchFactories.length; i++) {
            IPlaceLaunchFactoryViews launchFactory = IPlaceLaunchFactoryViews(_launchFactories[i]);
            try launchFactory.creatorRights(token) returns (IPlaceLaunchFactoryViews.CreatorRights memory rights) {
                return
                    PoolId.unwrap(rights.poolId) == PoolId.unwrap(key.toId())
                        && address(key.hooks) == launchFactory.hook();
            } catch {}
        }
        return false;
    }

    function launchFactories() external view returns (address[] memory) {
        return _launchFactories;
    }

    function collectionCount() external view returns (uint256) {
        return _collections.length;
    }

    function collectionAt(uint256 index) external view returns (address) {
        return _collections[index];
    }

    function collectionsOf(address token) external view returns (address[] memory) {
        return _collectionsOf[token];
    }

    // ───────────────────────────── Owner ─────────────────────────────

    /// @notice The template of new collections; existing collections keep theirs.
    function setImplementation(address newImplementation) external onlyOwner {
        _setImplementation(newImplementation);
    }

    function setPlatformRecipient(address recipient) external onlyOwner {
        _setPlatformRecipient(recipient);
    }

    /// @notice Swap routes of every collection (buyback, token pricing). Zero disables both.
    function setRewardRegistry(address registry) external onlyOwner {
        rewardRegistry = registry;
        emit RewardRegistrySet(registry);
    }

    /// @notice Reference prices of every collection. Zero disables token payments and buybacks.
    function setPriceGuard(address guard) external onlyOwner {
        priceGuard = guard;
        emit PriceGuardSet(guard);
    }

    function setWeth(address newWeth) external onlyOwner {
        weth = newWeth;
        emit WethSet(newWeth);
    }

    function setProjectRegistry(address registry) external onlyOwner {
        projectRegistry = registry;
        emit ProjectRegistrySet(registry);
    }

    function setCreationFee(uint256 fee) external onlyOwner {
        _setCreationFee(fee);
    }

    function addLaunchFactory(address launchFactory) external onlyOwner {
        if (launchFactory.code.length == 0) revert InvalidConfig();
        for (uint256 i = 0; i < _launchFactories.length; i++) {
            if (_launchFactories[i] == launchFactory) revert InvalidConfig();
        }
        _launchFactories.push(launchFactory);
        emit LaunchFactoryAdded(launchFactory);
    }

    function removeLaunchFactory(address launchFactory) external onlyOwner {
        uint256 n = _launchFactories.length;
        for (uint256 i = 0; i < n; i++) {
            if (_launchFactories[i] == launchFactory) {
                _launchFactories[i] = _launchFactories[n - 1];
                _launchFactories.pop();
                emit LaunchFactoryRemoved(launchFactory);
                return;
            }
        }
        revert InvalidConfig();
    }

    function _setImplementation(address newImplementation) internal {
        if (newImplementation.code.length == 0) revert InvalidConfig();
        implementation = newImplementation;
        emit ImplementationSet(newImplementation);
    }

    function _setPlatformRecipient(address recipient) internal {
        if (recipient == address(0)) revert InvalidConfig();
        platformRecipient = recipient;
        emit PlatformRecipientSet(recipient);
    }

    function _setCreationFee(uint256 fee) internal {
        if (fee > MAX_CREATION_FEE) revert InvalidConfig();
        creationFee = fee;
        emit CreationFeeSet(fee);
    }
}
