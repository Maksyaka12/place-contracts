// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

/// @notice The subset of Base's B20 factory precompile (`0xB20f…0000`, base-std `IB20Factory`) that Place uses.
/// @dev    `params` for the ASSET variant (0) = abi.encode(B20AssetCreateParams) (a tuple, so it starts with
///         an offset word; version = 1). `initCalls` run on the new token during creation and skip
///         role checks (not the mint receiver policy or pauses). LAUNCH.md §8.4.
interface IB20Factory {
    struct B20AssetCreateParams {
        uint8 version;
        string name;
        string symbol;
        address initialAdmin;
        uint8 decimals;
    }

    function createB20(uint8 variant, bytes32 salt, bytes calldata params, bytes[] calldata initCalls)
        external
        payable
        returns (address token);
    function getB20Address(uint8 variant, address sender, bytes32 salt) external view returns (address);
    function isB20(address token) external view returns (bool);
}

/// @notice The subset of a B20 token (base-std `IB20`) that Place uses at genesis and for metadata.
interface IB20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function supplyCap() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function pausedFeatures() external view returns (uint8[] memory);
    function policyId(bytes32 policyScope) external view returns (uint64);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MINT_ROLE() external view returns (bytes32);
    function BURN_ROLE() external view returns (bytes32);
    function BURN_BLOCKED_ROLE() external view returns (bytes32);
    function SEIZE_ROLE() external view returns (bytes32);
    function PAUSE_ROLE() external view returns (bytes32);
    function UNPAUSE_ROLE() external view returns (bytes32);
    function METADATA_ROLE() external view returns (bytes32);

    function TRANSFER_SENDER_POLICY() external view returns (bytes32);
    function TRANSFER_RECEIVER_POLICY() external view returns (bytes32);
    function TRANSFER_EXECUTOR_POLICY() external view returns (bytes32);
    function MINT_RECEIVER_POLICY() external view returns (bytes32);
    function SEIZE_EXEMPT_POLICY() external view returns (bytes32);
    function SEIZE_RECEIVER_POLICY() external view returns (bytes32);

    // Used only as `initCalls` at creation and by the METADATA_ROLE holder (the factory).
    function updateSupplyCap(uint256 newSupplyCap) external;
    function mint(address to, uint256 amount) external;
    function grantRole(bytes32 role, address account) external;
    function updateName(string calldata newName) external;
    function updateContractURI(string calldata newURI) external;
}
