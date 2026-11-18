// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The part of PlacePriceGuard that collections, the swapper and community vaults call.
interface IPlacePriceGuard {
    struct Config {
        uint32 minInterval;
        uint32 warmup;
        uint16 maxStepBps;
        uint16 maxDeviationBps;
    }

    function config() external view returns (Config memory);
    function observeRoute(PoolKey[] calldata route) external;
    function quote(PoolKey[] calldata route, address input, uint256 amountIn)
        external
        view
        returns (uint256 referenceOut, uint256 spotOut);
}

/// @notice The settings of PlaceNftFactory that its collections and its swapper read.
interface IPlaceNftFactory {
    function isCollection(address collection) external view returns (bool);
    function platformRecipient() external view returns (address);
    function rewardRegistry() external view returns (address);
    function priceGuard() external view returns (address);
    function swapper() external view returns (address);
    function weth() external view returns (address);
}

/// @notice PlaceNftSwapper: routes and guarded swaps of a factory's collections.
interface IPlaceNftSwapper {
    function swapFor(address input, uint256 amountIn, bool toPair) external payable returns (uint256 out);
    function observeMint(address collection) external;
    function quoteMint(address collection, uint256 ethAmount)
        external
        view
        returns (uint256 referenceOut, uint256 spotOut);
}

/// @notice The views of a PlaceNftCollection that community vaults check before an NFT campaign.
interface IPlaceNftCollection {
    function factory() external view returns (address);
    function token() external view returns (address);
    function official() external view returns (bool);
    function mintPrice() external view returns (uint128);
    function totalMinted() external view returns (uint32);
}
