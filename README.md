# Rebuild Uniswap V2

This repository contains Solidity smart contracts that adhere to specific standards and practices.

## Features and Standards

1. **Solidity Version:** Contracts are written in Solidity 0.8.0 or higher, eliminating the need for SafeMath due to built-in overflow/underflow protection.

2. **Fixed Point Library:** An existing fixed-point arithmetic library is utilized. Note: The Uniswap fixed-point library is not used in this project. PRBMathUD60x18 fixed-point library is used instead.

3. **Safe Transfers:** Instead of implementing `safeTransfer` from scratch as seen in some protocols (like Uniswap), this repository relies on tried and tested libraries such as OpenZeppelin's or Solmate's `safeTransfer`.

4. **Flash Swaps:** The implementation of flash swaps is aligned with the EIP 3156 standard. A critical note to developers: **Be exceedingly meticulous about when you update the reserves during this process.**
