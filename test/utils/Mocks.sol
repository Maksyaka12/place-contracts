// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPlaceHub, IPlaceConfig} from "../../src/place/interfaces/IPlaceHub.sol";

/// @notice Minimal stand-in for PlaceHub v1.0.0: takes pool + fee like the real hub and records the params.
contract MockHub is IPlaceHub, IPlaceConfig {
    uint16 public feeBps;
    CreateParams[] internal _created;
    address[] public creators;
    uint256[] public paid;

    function setFee(uint16 bps) external {
        feeBps = bps;
    }

    function config() external view returns (IPlaceConfig) {
        return IPlaceConfig(address(this));
    }

    function campaignFeeBps(address) external view returns (uint16) {
        return feeBps;
    }

    function createCampaign(CreateParams calldata p) external payable returns (uint256 id) {
        uint256 due = uint256(p.pool) + uint256(p.pool) * feeBps / 10_000;
        if (p.rewardToken == address(0)) {
            require(msg.value == due, "payment");
        } else {
            require(msg.value == 0, "payment");
            IERC20(p.rewardToken).transferFrom(msg.sender, address(this), due);
        }
        id = _created.length;
        _created.push(p);
        creators.push(msg.sender);
        paid.push(due);
    }

    function refundUnpublished(uint256 id) external {
        require(msg.sender == creators[id], "creator");
        uint256 amount = paid[id];
        paid[id] = 0;
        address reward = _created[id].rewardToken;
        if (reward == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "refund");
        } else {
            IERC20(reward).transfer(msg.sender, amount);
        }
    }

    function created(uint256 id) external view returns (CreateParams memory) {
        return _created[id];
    }

    function count() external view returns (uint256) {
        return _created.length;
    }
}

contract MockXRegistry {
    mapping(uint256 => address) public recipientOf;

    function bind(uint256 xId, address wallet) external {
        recipientOf[xId] = wallet;
    }
}

/// @notice FeeEscrow stand-in for vault-only fuzzing: `owed` ETH is paid out on `claimFor`.
contract MockEscrow {
    mapping(address => mapping(address => uint256)) public owed;

    function credit(address recipient) external payable {
        owed[recipient][address(0)] += msg.value;
    }

    function claimFor(address recipient, address currency) external {
        uint256 amount = owed[recipient][currency];
        owed[recipient][currency] = 0;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "pay");
    }
}

/// @notice Hook stand-in that only tells the vault its PoolManager.
contract MockHookPm {
    address public poolManager;

    constructor(address pm) {
        poolManager = pm;
    }
}
