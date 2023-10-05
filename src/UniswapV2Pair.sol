pragma solidity 0.8.21;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol";
import "./libraries/UQ112x112.sol";
import "./libraries/Math.sol";
import "./utils/SafeERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";
import "./interfaces/IERC3156FlashLender.sol";
import "./interfaces/IERC3156FlashBorrower.sol";
import {UD60x18} from "../lib/prb-math/src/UD60x18.sol";

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20, IERC3156FlashLender {
    using UQ112x112 for uint224;
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));

    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint256 private unlocked = 1;

    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN"); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "UniswapV2: OVERFLOW");

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        UD60x18 _kLast = UD60x18.wrap(kLast); // Convert to UD60x18

        UD60x18 res_0 = UD60x18.wrap(uint256(_reserve0));
        UD60x18 res_1 = UD60x18.wrap(uint256(_reserve1));

        if (feeOn) {
            if (_kLast != UD60x18.wrap(0)) {
                // Wrap 0 to UD60x18 for comparison
                UD60x18 rootK = res_0.mul(res_1).sqrt();
                UD60x18 rootKLast = _kLast.sqrt();

                if (rootK.gt(rootKLast)) {
                    UD60x18 numerator = UD60x18.wrap(totalSupply).mul(rootK.sub(rootKLast));
                    UD60x18 denominator = rootK.mul(UD60x18.wrap(5)).add(rootKLast);
                    uint256 liquidity = numerator.div(denominator).unwrap();

                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast.eq(UD60x18.wrap(0)) == false) {
            kLast = 0;
        }
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // Convert to UD60x18 type
        UD60x18 UD_reserve0 = UD60x18.wrap(uint256(_reserve0));
        UD60x18 UD_reserve1 = UD60x18.wrap(uint256(_reserve1));
        UD60x18 bal0 = UD60x18.wrap(balance0);
        UD60x18 bal1 = UD60x18.wrap(balance1);

        UD60x18 amount0 = bal0.sub(UD_reserve0);
        UD60x18 amount1 = bal1.sub(UD_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);

        UD60x18 _totalSupply = UD60x18.wrap(totalSupply);

        if (_totalSupply == UD60x18.wrap(0)) {
            liquidity = amount0.mul(amount1).sub(UD60x18.wrap(MINIMUM_LIQUIDITY)).sqrt().unwrap();
            _mint(address(0), MINIMUM_LIQUIDITY); 
        } else {
            // liquidity = min(amount0.mul(_totalSupply).div(reserve0), amount1.mul(_totalSupply).div(reserve1)).unwrap();
            liquidity = Math.min(
                amount0.mul(_totalSupply).div(UD_reserve0).unwrap(),
                (amount1.mul(_totalSupply).div(UD_reserve1)).unwrap()
            );
        }

        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity); // You might need to modify _mint to accept uint256

        _update(UD60x18.unwrap(bal0), UD60x18.unwrap(bal1), _reserve0, _reserve1); // Assuming _update accepts uint256
        if (feeOn) kLast = UD60x18.unwrap(UD_reserve0.mul(UD_reserve1)); // reserve0 and reserve1 are up-to-date, assuming kLast is uint256

        emit Mint(msg.sender, UD60x18.unwrap(amount0), UD60x18.unwrap(amount1)); // Assuming Mint event accepts uint256
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // address _token0 = token0;                                // gas savings
        // address _token1 = token1;                                // gas savings
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply;

        UD60x18 liqUD = UD60x18.wrap(liquidity);
        UD60x18 balance0UD = UD60x18.wrap(balance0);
        UD60x18 balance1UD = UD60x18.wrap(balance1);
        UD60x18 totalSupplyUD = UD60x18.wrap(_totalSupply);

        amount0 = liqUD.mul(balance0UD).div(totalSupplyUD).unwrap(); // using balances ensures pro-rata distribution
        amount1 = liqUD.mul(balance1UD).div(totalSupplyUD).unwrap(); // using balances ensures pro-rata distribution

        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) {
            UD60x18 reserve0UD = UD60x18.wrap(reserve0);
            UD60x18 reserve1UD = UD60x18.wrap(reserve1);
            kLast = reserve0UD.mul(reserve1UD).unwrap(); // reserve0 and reserve1 are up-to-date
        }

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            if (amount0Out > 0) IERC20(_token0).safeTransfer(to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) IERC20(_token1).safeTransfer(to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");

        {
            uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
            uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
            require(balance0Adjusted * balance1Adjusted >= _reserve0 * _reserve1 * 1000 ** 2, "UniswapV2: K");
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // Implement the `flashLoan` function from IERC3156FlashLender
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(token == token0 || token == token1, "UniswapV2: INVALID_TOKEN");
        uint256 fee = flashFee(token, amount);

        if (token == token0) {
            require(amount <= reserve0, "UniswapV2: INSUFFICIENT_LIQUIDITY");
            IERC20(token0).safeTransfer(address(receiver), amount);
        } else {
            require(amount <= reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");
            IERC20(token1).safeTransfer(address(receiver), amount);
        }

        // Execute the callback function on the borrower contract
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == CALLBACK_SUCCESS,
            "UniswapV2: CALLBACK_FAILED"
        );

        if (token == token0) {
            require(IERC20(token0).balanceOf(address(this)) >= reserve0 + fee, "UniswapV2: INSUFFICIENT_REPAYMENT");
        } else {
            require(IERC20(token1).balanceOf(address(this)) >= reserve1 + fee, "UniswapV2: INSUFFICIENT_REPAYMENT");
        }

        return true;
    }

    // return the maximum amount available for flash loans
    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token == token0) {
            return reserve0;
        } else if (token == token1) {
            return reserve1;
        } else {
            return 0;
        }
    }

    // Implement the `flashFee` function to determine the fee for the flash loan
    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        require(token == token0 || token == token1, "UniswapV2: INVALID_TOKEN");

        // For simplicity, let's assume a 0.03% fee.
        uint256 fee = UD60x18.unwrap(UD60x18.wrap(amount).div(UD60x18.wrap(3333)));

        // Ensure the fee does not exceed the reserves.
        if (token == token0) {
            require(fee < reserve0, "UniswapV2: INSUFFICIENT_RESERVE_FOR_FEE");
        } else if (token == token1){
            require(fee < reserve1, "UniswapV2: INSUFFICIENT_RESERVE_FOR_FEE");
        }

        return fee;
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings

        // convert these to UD60x18 types
        // UD60x18 currentBalance0 = UD60x18.wrap(IERC20(_token0).balanceOf(address(this)));
        // UD60x18 reserveBalance0 = UD60x18.wrap(uint256(reserve0));

        // UD60x18 currentBalance1 = UD60x18.wrap(IERC20(_token1).balanceOf(address(this)));
        // UD60x18 reserveBalance1 = UD60x18.wrap(uint256(reserve1));

        // Subtraction
        UD60x18 toTransfer0 = UD60x18.wrap(IERC20(_token0).balanceOf(address(this))).sub(UD60x18.wrap(uint256(reserve0)));
        UD60x18 toTransfer1 = UD60x18.wrap(IERC20(_token1).balanceOf(address(this))).sub(UD60x18.wrap(uint256(reserve1)));

        // ERC20 Safe transfer
        IERC20(_token0).safeTransfer(to, toTransfer0.unwrap());
        IERC20(_token1).safeTransfer(to, toTransfer1.unwrap());
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
