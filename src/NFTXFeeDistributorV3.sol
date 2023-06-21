// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {TransferLib} from "@src/lib/TransferLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INFTXRouter} from "@src/interfaces/INFTXRouter.sol";
import {INFTXVaultV3} from "@src/interfaces/INFTXVaultV3.sol";
import {IUniswapV3Pool} from "@uni-core/interfaces/IUniswapV3Pool.sol";
import {INFTXVaultFactoryV3} from "@src/interfaces/INFTXVaultFactoryV3.sol";
import {INFTXInventoryStakingV3} from "@src/interfaces/INFTXInventoryStakingV3.sol";

import {INFTXFeeDistributorV3} from "@src/interfaces/INFTXFeeDistributorV3.sol";

/**
 * @title NFTX Fee Distributor V3
 * @author @apoorvlathey
 *
 * @notice Allows distribution of vault fees between multiple receivers including inventory stakers and NFTX AMM liquidity providers.
 */
contract NFTXFeeDistributorV3 is
    INFTXFeeDistributorV3,
    Ownable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    INFTXVaultFactoryV3 public immutable override nftxVaultFactory;
    INFTXInventoryStakingV3 public immutable override inventoryStaking;
    IERC20 public immutable override WETH;
    uint24 public constant override REWARD_FEE_TIER = 10_000;

    // =============================================================
    //                            STORAGE
    // =============================================================

    INFTXRouter public override nftxRouter;
    address public override treasury;

    // Total of allocation points per feeReceiver.
    uint256 public override allocTotal;
    FeeReceiver[] public override feeReceivers;

    bool public override distributionPaused;

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(
        INFTXVaultFactoryV3 nftxVaultFactory_,
        INFTXInventoryStakingV3 inventoryStaking_,
        INFTXRouter nftxRouter_,
        address treasury_
    ) {
        nftxVaultFactory = nftxVaultFactory_;
        inventoryStaking = inventoryStaking_;
        WETH = IERC20(nftxRouter_.WETH());
        nftxRouter = nftxRouter_;
        treasury = treasury_;

        // set 80% allocation to liquidity providers
        _addReceiver(address(0), 0.8 ether, ReceiverType.POOL);
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL WRITE
    // =============================================================

    function distribute(uint256 vaultId) external override nonReentrant {
        INFTXVaultV3 vault = INFTXVaultV3(nftxVaultFactory.vault(vaultId));

        uint256 wethBalance = WETH.balanceOf(address(this));

        if (distributionPaused || allocTotal == 0) {
            WETH.transfer(treasury, wethBalance);
            return;
        }

        uint256 leftover;
        for (uint256 i; i < feeReceivers.length; ) {
            FeeReceiver storage feeReceiver = feeReceivers[i];

            uint256 wethAmountToSend = leftover +
                (wethBalance * feeReceiver.allocPoint) /
                allocTotal;

            bool tokenSent = _sendForReceiver(
                feeReceiver,
                wethAmountToSend,
                vaultId,
                vault
            );
            leftover += tokenSent ? 0 : wethAmountToSend;

            unchecked {
                ++i;
            }
        }

        if (leftover > 0) {
            WETH.transfer(treasury, leftover);
        }
    }

    // =============================================================
    //                        ONLY OWNER WRITE
    // =============================================================

    function addReceiver(
        address receiver,
        uint256 allocPoint,
        ReceiverType receiverType
    ) external override onlyOwner {
        _addReceiver(receiver, allocPoint, receiverType);
    }

    function changeReceiverAlloc(
        uint256 receiverId,
        uint256 allocPoint
    ) external override onlyOwner {
        if (receiverId >= feeReceivers.length) revert IdOutOfBounds();

        FeeReceiver storage feeReceiver = feeReceivers[receiverId];
        allocTotal -= feeReceiver.allocPoint;
        feeReceiver.allocPoint = allocPoint;
        allocTotal += allocPoint;

        emit UpdateFeeReceiverAlloc(feeReceiver.receiver, allocPoint);
    }

    function changeReceiverAddress(
        uint256 receiverId,
        address receiver,
        ReceiverType receiverType
    ) external override onlyOwner {
        if (receiverId >= feeReceivers.length) revert IdOutOfBounds();

        FeeReceiver storage feeReceiver = feeReceivers[receiverId];
        address oldReceiver = feeReceiver.receiver;
        feeReceiver.receiver = receiver;
        feeReceiver.receiverType = receiverType;

        emit UpdateFeeReceiverAddress(oldReceiver, receiver);
    }

    function removeReceiver(uint256 receiverId) external override onlyOwner {
        uint256 arrLength = feeReceivers.length;
        if (receiverId >= arrLength) revert IdOutOfBounds();

        emit RemoveFeeReceiver(feeReceivers[receiverId].receiver);

        allocTotal -= feeReceivers[receiverId].allocPoint;
        // Copy the last element to what is being removed and remove the last element.
        feeReceivers[receiverId] = feeReceivers[arrLength - 1];
        feeReceivers.pop();
    }

    function setTreasuryAddress(address treasury_) external override onlyOwner {
        if (treasury_ == address(0)) revert AddressIsZero();

        treasury = treasury_;
        emit UpdateTreasuryAddress(treasury_);
    }

    // TODO: add function to change NFTXRouter address

    function pauseFeeDistribution(bool pause) external override onlyOwner {
        distributionPaused = pause;
        emit PauseDistribution(pause);
    }

    function rescueTokens(IERC20 token) external override onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(msg.sender, balance);
    }

    // =============================================================
    //                      INTERNAL / PRIVATE
    // =============================================================

    function _addReceiver(
        address receiver,
        uint256 allocPoint,
        ReceiverType receiverType
    ) internal {
        FeeReceiver memory feeReceiver = FeeReceiver({
            receiver: receiver,
            allocPoint: allocPoint,
            receiverType: receiverType
        });
        feeReceivers.push(feeReceiver);
        allocTotal += allocPoint;
        emit AddFeeReceiver(receiver, allocPoint);
    }

    function _sendForReceiver(
        FeeReceiver storage feeReceiver,
        uint256 wethAmountToSend,
        uint256 vaultId,
        INFTXVaultV3 vault
    ) internal returns (bool tokenSent) {
        if (feeReceiver.receiverType == ReceiverType.INVENTORY) {
            TransferLib.maxApprove(
                address(WETH),
                feeReceiver.receiver,
                wethAmountToSend
            );

            // Inventory Staking might not pull tokens in case where `vaultGlobal[vaultId].totalVTokenShares` is zero
            bool pulledTokens = inventoryStaking.receiveWethRewards(
                vaultId,
                wethAmountToSend
            );

            tokenSent = pulledTokens;
        } else if (feeReceiver.receiverType == ReceiverType.POOL) {
            (address pool, bool exists) = nftxRouter.getPoolExists(
                vaultId,
                REWARD_FEE_TIER
            );

            if (exists) {
                uint256 liquidity = IUniswapV3Pool(pool).liquidity();

                if (liquidity > 0) {
                    WETH.transfer(pool, wethAmountToSend);
                    IUniswapV3Pool(pool).distributeRewards(
                        wethAmountToSend,
                        !nftxRouter.isVToken0(address(vault))
                    );

                    tokenSent = true;
                }
            }
        } else {
            WETH.transfer(feeReceiver.receiver, wethAmountToSend);
            tokenSent = true;
        }
    }
}
