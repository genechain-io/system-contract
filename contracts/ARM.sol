// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./ERC20.sol";


/**
 * @title ARM ERC20 Token
 * @dev Mintable ERC20 token with burning and optional functions implemented.
 * Any address with minter role can mint new tokens.
 * For full specification of ERC-20 standard see:
 * https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20.md
 */
contract ARM is ERC20 {
    using SafeMath for uint256;
    
    string private constant _name = "ARM";
    string private constant _symbol = "ARM";
    uint8 private constant _decimals = 18;
    
    address public SrcTokenAddr;
    address public constant ARMAdmin = 0x15973636A677F7f87B00423444021ad904856bE3;
    
    struct ExchangeInfo {
        string memo;
        uint256 amount;
    }
    
    mapping(address => ExchangeInfo) exchangeInfo;
    
    event LogMemoSet(address indexed acc, string memo);
    
    modifier onlySrcTokenSet() {
        require(SrcTokenAddr != address(0), "Source token address not set");
        _;
    }

    modifier onlySrcTokenNotSet() {
        require(SrcTokenAddr == address(0), "Source token address is set");
        _;
    }

    function setSrcToken(address srcToken) public onlySrcTokenNotSet {
        require(srcToken != address(0), "Source token address cannot be 0");
        require(msg.sender == ARMAdmin, "Only ARMAdmin can set src token");
        SrcTokenAddr = srcToken;
    }

    /**
     * @dev setMemo set exchange memo info 
     * @param memo The amount of lowest token units to be burned.
     */
    function setMemo(string calldata memo) public onlySrcTokenSet {
        require(bytes(memo).length <= 64, "Invalidate memo length");
        exchangeInfo[msg.sender].memo = memo;
        emit LogMemoSet(msg.sender, memo);
    }
    
    /**
     * @return the symbol of the token.
     */
    function getExchangeInfo(address acc) public view returns (string memory, uint256) {
      return (exchangeInfo[acc].memo, exchangeInfo[acc].amount);
    }
    
    /**
     * @dev exchange src token to ARM
     * @param value The amount of lowest token units to be burned.
     */
    function exchange(uint256 value) public onlySrcTokenSet {
        require(value > 0, "Amount should greator than 0");
        TransferHelper.safeTransferFrom(SrcTokenAddr, msg.sender, address(this), value);
        _mint(msg.sender, value);
        exchangeInfo[msg.sender].amount = exchangeInfo[msg.sender].amount.add(value);
    }
    
    /**
     * @dev Burns a specific amount of tokens.
     * @param value The amount of lowest token units to be burned.
     */
    function burn(uint256 value) public onlySrcTokenSet {
      require(value <= exchangeInfo[msg.sender].amount, "Not enough amount to burn");
      _burn(msg.sender, value);
      TransferHelper.safeTransfer(SrcTokenAddr, msg.sender, value);
      exchangeInfo[msg.sender].amount = exchangeInfo[msg.sender].amount.sub(value);
    }

    // optional functions from ERC20 stardard

    /**
     * @return the name of the token.
     */
    function name() public pure returns (string memory) {
      return _name;
    }

    /**
     * @return the symbol of the token.
     */
    function symbol() public pure returns (string memory) {
      return _symbol;
    }

    /**
     * @return the number of decimals of the token.
     */
    function decimals() public pure returns (uint8) {
      return _decimals;
    }
}