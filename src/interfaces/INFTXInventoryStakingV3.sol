// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

import {IERC721Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INFTXVaultFactory} from "@src/v2/interface/INFTXVaultFactory.sol";
import {ITimelockExcludeList} from "@src/v2/interface/ITimelockExcludeList.sol";

interface INFTXInventoryStakingV3 is IERC721Upgradeable {
    // details about the staking position
    struct Position {
        // the nonce for permits
        uint256 nonce; // TODO: add permit logic
        // vaultId corresponding to the vTokens staked in this position
        uint256 vaultId;
        // timestamp at which the timelock expires
        uint256 timelockedUntil;
        // shares balance is used to track position's ownership of total vToken balance
        uint256 vTokenShareBalance;
        // used to evaluate weth fees accumulated per vTokenShare since this snapshot
        uint256 wethFeesPerVTokenShareSnapshotX128;
        // owed weth fees, updates when positions merged
        uint256 wethOwed;
    }

    struct VaultGlobal {
        uint256 netVTokenBalance; // vToken liquidity + earned fees
        uint256 totalVTokenShares;
        uint256 globalWethFeesPerVTokenShareX128;
    }

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    function CRYPTO_PUNKS() external view returns (address);

    function nftxVaultFactory() external view returns (INFTXVaultFactory);

    function timelockExcludeList() external view returns (ITimelockExcludeList);

    function WETH() external view returns (IERC20);

    // =============================================================
    //                            STORAGE
    // =============================================================

    function timelock() external view returns (uint256);

    function earlyWithdrawPenaltyInWei() external view returns (uint256);

    function positions(
        uint256 positionId
    )
        external
        view
        returns (
            uint256 nonce,
            uint256 vaultId,
            uint256 timelockedUntil,
            uint256 vTokenShareBalance,
            uint256 wethFeesPerVTokenShareSnapshotX128,
            uint256 wethOwed
        );

    function vaultGlobal(
        uint256 vaultId
    )
        external
        view
        returns (
            uint256 netVTokenBalance,
            uint256 totalVTokenShares,
            uint256 globalWethFeesPerVTokenShareX128
        );

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Deposit(
        uint256 indexed vaultId,
        uint256 indexed positionId,
        uint256 amount
    );
    event DepositWithNFT(
        uint256 indexed vaultId,
        uint256 indexed positionId,
        uint256 amount
    );
    event Withdraw(
        uint256 indexed positionId,
        uint256 vTokenShares,
        uint256 vTokenAmount,
        uint256 wethAmount
    );
    event CollectWethFees(uint256 indexed positionId, uint256 wethAmount);
    event UpdateTimelock(uint256 newTimelock);
    event UpdateEarlyWithdrawPenalty(uint256 newEarlyWithdrawPenaltyInWei);

    // =============================================================
    //                            ERRORS
    // =============================================================

    error TimelockTooLong();
    error InvalidEarlyWithdrawPenalty();
    error NotPositionOwner();
    error Timelocked();
    error VaultIdMismatch();
    error ParentChildSame();

    // =============================================================
    //                           INIT
    // =============================================================

    function __NFTXInventoryStaking_init(
        INFTXVaultFactory nftxVaultFactory_,
        uint256 timelock_,
        uint256 earlyWithdrawPenaltyInWei_,
        ITimelockExcludeList timelockExcludeList_
    ) external;

    // =============================================================
    //                     PUBLIC / EXTERNAL WRITE
    // =============================================================

    function deposit(
        uint256 vaultId,
        uint256 amount,
        address recipient
    ) external returns (uint256 positionId);

    /// @notice This contract must be on the feeExclusion list to avoid mint fees, else revert
    function depositWithNFT(
        uint256 vaultId,
        uint256[] calldata tokenIds,
        address recipient
    ) external returns (uint256 positionId);

    function withdraw(uint256 positionId, uint256 vTokenShares) external;

    function combinePositions(
        uint256 parentPositionId,
        uint256[] calldata childPositionIds
    ) external;

    function collectWethFees(uint256 positionId) external;

    function receiveRewards(
        uint256 vaultId,
        uint256 amount,
        bool isRewardWeth
    ) external returns (bool);

    // =============================================================
    //                        ONLY OWNER WRITE
    // =============================================================

    function setTimelock(uint256 timelock_) external;

    function setEarlyWithdrawPenalty(
        uint256 earlyWithdrawPenaltyInWei_
    ) external;

    // =============================================================
    //                     PUBLIC / EXTERNAL VIEW
    // =============================================================

    function pricePerShareVToken(
        uint256 vaultId
    ) external view returns (uint256);
}
