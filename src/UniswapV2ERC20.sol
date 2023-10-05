pragma solidity 0.8.21;

import "./interfaces/IUniswapV2ERC20.sol";
import {UD60x18, wrap, unwrap} from "../lib/prb-math/src/UD60x18.sol";
import "../lib/prb-math/src/ud60x18/Constants.sol";

contract UniswapV2ERC20 is IUniswapV2ERC20 {

    string public constant name = "Uniswap V2";
    string public constant symbol = "UNI-V2";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint256) public nonces;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor() {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint256 value) internal {
        UD60x18 wrappedValue = wrap(value);
        UD60x18 wrappedTotalSupply = wrap(totalSupply);

        wrappedTotalSupply = wrappedTotalSupply.add(wrappedValue);
        balanceOf[to] = unwrap(wrap(balanceOf[to]).add(wrappedValue));

        totalSupply = unwrap(wrappedTotalSupply);

        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        UD60x18 wrappedValue = wrap(value);
        UD60x18 wrappedBalanceOfFrom = wrap(balanceOf[from]);
        UD60x18 wrappedTotalSupply = wrap(totalSupply);

        balanceOf[from] = unwrap(wrappedBalanceOfFrom.sub(wrappedValue)); 
        totalSupply = unwrap(wrappedTotalSupply.sub(wrappedValue));

        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint256 value) private {
        balanceOf[from] = unwrap(wrap(balanceOf[from]).sub(wrap(value)));
        balanceOf[to] = unwrap(wrap(balanceOf[to]).add(wrap(value)));
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        UD60x18 wrappedAllowance = UD60x18.wrap(allowance[from][msg.sender]);
        if (wrappedAllowance != MAX_UD60x18) {
            allowance[from][msg.sender] = UD60x18.unwrap(wrappedAllowance.sub(wrap(value)));
        }

        _transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(deadline >= block.timestamp, "UniswapV2: EXPIRED");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "UniswapV2: INVALID_SIGNATURE");
        _approve(owner, spender, value);
    }
}
