// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @title Treasury
 * @dev This contract locks a specific amount of RNA for develop team, 
 * and releases every season.
 */
 
contract Treasury {
    uint256 public constant SeasonFund = 187_500 ether; // fund releases every season
    uint8 public constant MaxRedeemCount = 16; // can redeem 16 times
    uint32 public constant RedeemInterval = 2_628_000; // can redeem every 2,628,000 blocks (a season)
    address payable public constant RedeemAccount = 0x15973636A677F7f87B00423444021ad904856bE3;
    
    uint8 redeemCount = 0;
    
    event LogTreasuryRedeem(
        address indexed redeemBy,
        uint8 indexed season,
        uint256 time
    );
    
    /**
     * @dev redeem
     * redeem fund, can redeem only once per season
     */
    function redeem() public {
        require(redeemCount < MaxRedeemCount, "Fund is empty.");
        require(block.number >= RedeemInterval * redeemCount, "Next redeemable block in future.");
        RedeemAccount.transfer(SeasonFund);
        redeemCount += 1;
        emit LogTreasuryRedeem(msg.sender, redeemCount, block.timestamp);
    }
}
