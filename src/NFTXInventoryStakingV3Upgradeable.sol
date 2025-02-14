// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.15;

// inheriting
import {PausableUpgradeable} from "@src/custom/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import {ERC721PermitUpgradeable, ERC721EnumerableUpgradeable} from "@src/custom/tokens/ERC721/ERC721PermitUpgradeable.sol";
import {ERC1155HolderUpgradeable, ERC1155ReceiverUpgradeable, IERC165Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";

// libs
import {Base64} from "base64-sol/base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeCast} from "@uni-core/libraries/SafeCast.sol";
import {FullMath} from "@uni-core/libraries/FullMath.sol";
import {TransferLib} from "@src/lib/TransferLib.sol";
import {FixedPoint128} from "@uni-core/libraries/FixedPoint128.sol";

// interfaces
import {IWETH9} from "@uni-periphery/interfaces/external/IWETH9.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {INFTXVaultV3} from "@src/interfaces/INFTXVaultV3.sol";
import {INFTXVaultFactoryV3} from "@src/interfaces/INFTXVaultFactoryV3.sol";
import {ITimelockExcludeList} from "@src/interfaces/ITimelockExcludeList.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPermitAllowanceTransfer} from "@src/interfaces/external/IPermitAllowanceTransfer.sol";
import {InventoryStakingDescriptor} from "@src/custom/InventoryStakingDescriptor.sol";

import {INFTXInventoryStakingV3} from "@src/interfaces/INFTXInventoryStakingV3.sol";

/**
 * @title NFTX Inventory Staking V3
 * @author @apoorvlathey
 *
 * @dev lockId's:
 * 0: deposit
 * 1: depositWithNFT
 * 2: withdraw
 * 3: collectWethFees
 * 4: increasePosition
 *
 * @notice Allows users to stake vTokens to earn fees in vTokens and WETH. The position is minted as xNFT.
 * @dev This contract must be on the feeExclusion list to avoid redeem fees, else revert.
 */

contract NFTXInventoryStakingV3Upgradeable is
    INFTXInventoryStakingV3,
    ERC721PermitUpgradeable,
    ERC1155HolderUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Strings for uint256;
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 public constant override MINIMUM_LIQUIDITY = 1_000;
    uint256 private constant VTOKEN_TIMELOCK = 1 hours;

    IWETH9 public immutable override WETH;
    IPermitAllowanceTransfer public immutable override PERMIT2;
    INFTXVaultFactoryV3 public immutable override nftxVaultFactory;

    // "constants": only set during initialization
    ITimelockExcludeList public override timelockExcludeList;

    uint256 constant MAX_TIMELOCK = 14 days;
    uint256 constant MAX_EARLY_WITHDRAW_PENALTY = 1 ether;
    uint256 constant BASE = 1 ether;

    // =============================================================
    //                          VARIABLES
    // =============================================================

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId;

    /// @dev timelock in seconds
    uint256 public override timelock;
    /// @dev the max penalty applicable. The penalty goes down linearly as the `timelockedUntil` approaches
    uint256 public override earlyWithdrawPenaltyInWei;

    /// @dev The token ID position data
    mapping(uint256 => Position) public override positions;

    /// @dev vaultId => VaultGlobal
    mapping(uint256 => VaultGlobal) public override vaultGlobal;

    InventoryStakingDescriptor public override descriptor;

    // =============================================================
    //                           INIT
    // =============================================================

    constructor(
        IWETH9 WETH_,
        IPermitAllowanceTransfer PERMIT2_,
        INFTXVaultFactoryV3 nftxVaultFactory_
    ) {
        WETH = WETH_;
        PERMIT2 = PERMIT2_;
        nftxVaultFactory = nftxVaultFactory_;
    }

    function __NFTXInventoryStaking_init(
        uint256 timelock_,
        uint256 earlyWithdrawPenaltyInWei_,
        ITimelockExcludeList timelockExcludeList_,
        InventoryStakingDescriptor descriptor_
    ) external override initializer {
        __ERC721PermitUpgradeable_init("NFTX Inventory Staking", "xNFT", "1");
        __Pausable_init();
        __ReentrancyGuard_init();

        if (timelock_ > MAX_TIMELOCK) revert TimelockTooLong();
        if (earlyWithdrawPenaltyInWei_ > MAX_EARLY_WITHDRAW_PENALTY)
            revert InvalidEarlyWithdrawPenalty();
        timelock = timelock_;
        earlyWithdrawPenaltyInWei = earlyWithdrawPenaltyInWei_;
        timelockExcludeList = timelockExcludeList_;
        descriptor = descriptor_;

        _nextId = 1;
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL WRITE
    // =============================================================

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function deposit(
        uint256 vaultId,
        uint256 amount,
        address recipient,
        bytes calldata encodedPermit2,
        bool viaPermit2,
        bool forceTimelock
    ) external override returns (uint256 positionId) {
        address vToken = nftxVaultFactory.vault(vaultId);
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];

        uint256 preVTokenBalance = IERC20(vToken).balanceOf(address(this));

        if (viaPermit2) {
            if (encodedPermit2.length > 0) {
                (
                    address _owner,
                    IPermitAllowanceTransfer.PermitSingle memory permitSingle,
                    bytes memory signature
                ) = abi.decode(
                        encodedPermit2,
                        (address, IPermitAllowanceTransfer.PermitSingle, bytes)
                    );

                PERMIT2.permit(_owner, permitSingle, signature);
            }

            PERMIT2.transferFrom(
                msg.sender,
                address(this),
                SafeCast.toUint160(amount),
                address(vToken)
            );
        } else {
            IERC20(vToken).transferFrom(msg.sender, address(this), amount);
        }

        return
            _deposit(
                vaultId,
                amount,
                recipient,
                _vaultGlobal,
                preVTokenBalance,
                forceTimelock
            );
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function depositWithNFT(
        uint256 vaultId,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address recipient
    ) external returns (uint256 positionId) {
        onlyOwnerIfPaused(1);

        address vToken = nftxVaultFactory.vault(vaultId);
        uint256 preVTokenBalance = IERC20(vToken).balanceOf(address(this));

        uint256 amount;
        {
            address assetAddress = INFTXVaultV3(vToken).assetAddress();

            if (!INFTXVaultV3(vToken).is1155()) {
                // tranfer NFTs from user to the vault
                TransferLib.transferFromERC721(
                    assetAddress,
                    address(vToken),
                    tokenIds
                );
            } else {
                IERC1155(assetAddress).safeBatchTransferFrom(
                    msg.sender,
                    address(this),
                    tokenIds,
                    amounts,
                    ""
                );

                IERC1155(assetAddress).setApprovalForAll(address(vToken), true);
            }

            // mint vTokens
            amount = INFTXVaultV3(vToken).mint(
                tokenIds,
                amounts,
                msg.sender,
                address(this)
            );
        }

        _mint(recipient, (positionId = _nextId++));

        {
            VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];

            uint256 vTokenShares = _mintVTokenShares(
                _vaultGlobal,
                amount,
                preVTokenBalance
            );

            uint256 _timelock = timelock;
            positions[positionId] = Position({
                nonce: 0,
                vaultId: vaultId,
                timelockedUntil: _getTimelockedUntil(vaultId, _timelock),
                timelock: _timelock,
                vTokenTimelockedUntil: 0,
                vTokenShareBalance: vTokenShares,
                wethFeesPerVTokenShareSnapshotX128: _vaultGlobal
                    .globalWethFeesPerVTokenShareX128,
                wethOwed: 0
            });
        }

        emit DepositWithNFT(vaultId, positionId, tokenIds, amounts);
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function increasePosition(
        uint256 positionId,
        uint256 amount,
        bytes calldata encodedPermit2,
        bool viaPermit2,
        bool forceTimelock
    ) external {
        if (ownerOf(positionId) != msg.sender) revert NotPositionOwner();

        Position storage position = positions[positionId];

        uint256 vaultId = position.vaultId;
        address vToken = nftxVaultFactory.vault(vaultId);

        uint256 preVTokenBalance = IERC20(vToken).balanceOf(address(this));

        if (viaPermit2) {
            if (encodedPermit2.length > 0) {
                (
                    address _owner,
                    IPermitAllowanceTransfer.PermitSingle memory permitSingle,
                    bytes memory signature
                ) = abi.decode(
                        encodedPermit2,
                        (address, IPermitAllowanceTransfer.PermitSingle, bytes)
                    );

                PERMIT2.permit(_owner, permitSingle, signature);
            }

            PERMIT2.transferFrom(
                msg.sender,
                address(this),
                SafeCast.toUint160(amount),
                address(vToken)
            );
        } else {
            IERC20(vToken).transferFrom(msg.sender, address(this), amount);
        }

        return
            _increasePosition(
                positionId,
                position,
                vaultId,
                amount,
                preVTokenBalance,
                forceTimelock
            );
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function withdraw(
        uint256 positionId,
        uint256 vTokenShares,
        uint256[] calldata nftIds,
        uint256 vTokenPremiumLimit
    ) external payable override nonReentrant {
        onlyOwnerIfPaused(2);

        if (ownerOf(positionId) != msg.sender) revert NotPositionOwner();

        address vToken;
        uint256 vTokenOwed;
        uint256 wethOwed;
        uint256 _timelockedUntil;
        {
            Position storage position = positions[positionId];

            if (block.timestamp <= position.vTokenTimelockedUntil)
                revert Timelocked();
            uint256 positionVTokenShareBalance = position.vTokenShareBalance;
            if (positionVTokenShareBalance < vTokenShares)
                revert InsufficientVTokenShares();

            VaultGlobal storage _vaultGlobal;
            {
                uint256 vaultId = position.vaultId;
                _vaultGlobal = vaultGlobal[vaultId];
                vToken = nftxVaultFactory.vault(vaultId);
            }

            // cache
            uint256 _totalVTokenShares = _vaultGlobal.totalVTokenShares;
            // withdraw vTokens corresponding to the vTokenShares requested
            vTokenOwed =
                (IERC20(vToken).balanceOf(address(this)) * vTokenShares) /
                _totalVTokenShares;

            {
                // cache
                uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal
                    .globalWethFeesPerVTokenShareX128;
                // withdraw all the weth fees accrued
                {
                    wethOwed =
                        _calcWethOwed(
                            _globalWethFeesPerVTokenShareX128,
                            position.wethFeesPerVTokenShareSnapshotX128,
                            positionVTokenShareBalance
                        ) +
                        position.wethOwed;
                }
                position
                    .wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
                position.wethOwed = 0;
            }

            // cache
            _timelockedUntil = position.timelockedUntil;

            if (block.timestamp <= _timelockedUntil) {
                // Eg: timelock = 10 days, vTokenOwed = 100, penalty% = 5%
                // Case 1: Instant withdraw, with 10 days left
                // penaltyAmt = 100 * 5% = 5
                // Case 2: With 2 days timelock left
                // penaltyAmt = (100 * 5%) * 2 / 10 = 1
                uint256 vTokenPenalty = ((_timelockedUntil - block.timestamp) *
                    vTokenOwed *
                    earlyWithdrawPenaltyInWei) / (position.timelock * BASE);
                vTokenOwed -= vTokenPenalty;
            }

            // in case of penalty, more shares are burned than the corresponding vToken balance
            // resulting in an increase of `pricePerShareVToken`, hence the penalty collected is distributed amongst other stakers
            _vaultGlobal.totalVTokenShares = _totalVTokenShares - vTokenShares;
            position.vTokenShareBalance -= vTokenShares;
        }

        uint256 nftCount = nftIds.length;
        if (nftCount > 0) {
            // check if we have sufficient vTokens
            uint256 requiredVTokens = nftCount * BASE;
            if (vTokenOwed < requiredVTokens) revert InsufficientVTokens();

            {
                // send vToken residue first
                {
                    uint256 vTokenResidue;
                    unchecked {
                        vTokenResidue = vTokenOwed - requiredVTokens;
                    }
                    if (vTokenResidue > 0) {
                        IERC20(vToken).transfer(msg.sender, vTokenResidue);
                    }
                }

                INFTXVaultV3(vToken).redeem{value: msg.value}(
                    nftIds,
                    msg.sender,
                    0,
                    vTokenPremiumLimit,
                    _timelockedUntil == 0 // forcing fees for positions which never were under timelock (or else they can bypass redeem fees as deposit was made in vTokens)
                );
            }
        } else {
            // transfer tokens to the user
            IERC20(vToken).transfer(msg.sender, vTokenOwed);
        }
        WETH.transfer(msg.sender, wethOwed);

        uint256 ethResidue = address(this).balance;
        TransferLib.transferETH(msg.sender, ethResidue);

        emit Withdraw(positionId, vTokenShares, vTokenOwed, wethOwed);
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function combinePositions(
        uint256 parentPositionId,
        uint256[] calldata childPositionIds
    ) external override {
        // `ownerOf` handles invalid positionId
        if (ownerOf(parentPositionId) != msg.sender) revert NotPositionOwner();
        Position storage parentPosition = positions[parentPositionId];
        uint256 parentVaultId = parentPosition.vaultId;

        VaultGlobal storage _vaultGlobal = vaultGlobal[parentVaultId];

        if (
            block.timestamp <= parentPosition.timelockedUntil ||
            block.timestamp <= parentPosition.vTokenTimelockedUntil
        ) revert Timelocked();

        // cache
        uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal
            .globalWethFeesPerVTokenShareX128;
        uint256 _parentVTokenShareBalance = parentPosition.vTokenShareBalance;

        // weth owed for the parent position
        uint256 netWethOwed = _calcWethOwed(
            _globalWethFeesPerVTokenShareX128,
            parentPosition.wethFeesPerVTokenShareSnapshotX128,
            _parentVTokenShareBalance
        );
        uint256 childrenPositionsCount = childPositionIds.length;
        for (uint256 i; i < childrenPositionsCount; ) {
            if (childPositionIds[i] == parentPositionId)
                revert ParentChildSame();
            // `ownerOf` handles invalid positionId
            if (ownerOf(childPositionIds[i]) != msg.sender)
                revert NotPositionOwner();

            Position storage childPosition = positions[childPositionIds[i]];
            if (
                block.timestamp <= childPosition.timelockedUntil ||
                block.timestamp <= childPosition.vTokenTimelockedUntil
            ) revert Timelocked();
            if (childPosition.vaultId != parentVaultId)
                revert VaultIdMismatch();

            // cache
            uint256 _childVTokenShareBalance = childPosition.vTokenShareBalance;

            // add weth owed for this child position
            netWethOwed +=
                _calcWethOwed(
                    _globalWethFeesPerVTokenShareX128,
                    childPosition.wethFeesPerVTokenShareSnapshotX128,
                    _childVTokenShareBalance
                ) +
                childPosition.wethOwed;
            // transfer vToken share balance to parent position
            _parentVTokenShareBalance += _childVTokenShareBalance;
            childPosition.vTokenShareBalance = 0;
            childPosition.wethOwed = 0;

            unchecked {
                ++i;
            }
        }

        // set new wethFeesPerVTokenShare snapshot
        parentPosition
            .wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
        parentPosition.vTokenShareBalance = _parentVTokenShareBalance;

        // add net wethOwed to the parent position
        parentPosition.wethOwed += netWethOwed;

        emit CombinePositions(parentPositionId, childPositionIds);
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function collectWethFees(uint256[] calldata positionIds) external {
        onlyOwnerIfPaused(3);

        uint256 totalWethOwed;
        uint256 wethOwed;
        uint256 len = positionIds.length;
        for (uint256 i; i < len; ) {
            if (ownerOf(positionIds[i]) != msg.sender)
                revert NotPositionOwner();

            Position storage position = positions[positionIds[i]];
            VaultGlobal storage _vaultGlobal = vaultGlobal[position.vaultId];

            // cache
            uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal
                .globalWethFeesPerVTokenShareX128;

            wethOwed =
                _calcWethOwed(
                    _globalWethFeesPerVTokenShareX128,
                    position.wethFeesPerVTokenShareSnapshotX128,
                    position.vTokenShareBalance
                ) +
                position.wethOwed;
            totalWethOwed += wethOwed;

            position
                .wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
            position.wethOwed = 0;

            emit CollectWethFees(positionIds[i], wethOwed);

            unchecked {
                ++i;
            }
        }

        WETH.transfer(msg.sender, totalWethOwed);
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function receiveWethRewards(
        uint256 vaultId,
        uint256 wethAmount
    ) external override returns (bool rewardsDistributed) {
        if (msg.sender != nftxVaultFactory.feeDistributor())
            revert SenderNotFeeDistributor();

        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        if (_vaultGlobal.totalVTokenShares == 0) {
            return false;
        }
        rewardsDistributed = true;

        WETH.transferFrom(msg.sender, address(this), wethAmount);
        _vaultGlobal.globalWethFeesPerVTokenShareX128 += FullMath.mulDiv(
            wethAmount,
            FixedPoint128.Q128,
            _vaultGlobal.totalVTokenShares
        );
    }

    // =============================================================
    //                        ONLY OWNER WRITE
    // =============================================================

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function setTimelock(uint256 timelock_) external override onlyOwner {
        if (timelock_ > MAX_TIMELOCK) revert TimelockTooLong();

        timelock = timelock_;
        emit UpdateTimelock(timelock_);
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function setEarlyWithdrawPenalty(
        uint256 earlyWithdrawPenaltyInWei_
    ) external override onlyOwner {
        if (earlyWithdrawPenaltyInWei_ > MAX_EARLY_WITHDRAW_PENALTY)
            revert InvalidEarlyWithdrawPenalty();

        earlyWithdrawPenaltyInWei = earlyWithdrawPenaltyInWei_;
        emit UpdateEarlyWithdrawPenalty(earlyWithdrawPenaltyInWei_);
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function setDescriptor(
        InventoryStakingDescriptor descriptor_
    ) external override onlyOwner {
        if (address(descriptor_) == address(0)) revert ZeroAddress();

        descriptor = descriptor_;
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL VIEW
    // =============================================================

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function pricePerShareVToken(
        uint256 vaultId
    ) external view override returns (uint256) {
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        address vToken = nftxVaultFactory.vault(vaultId);

        return
            (IERC20(vToken).balanceOf(address(this)) * BASE) /
            _vaultGlobal.totalVTokenShares;
    }

    /**
     * @inheritdoc INFTXInventoryStakingV3
     */
    function wethBalance(
        uint256 positionId
    ) public view override returns (uint256) {
        Position memory position = positions[positionId];
        VaultGlobal memory _vaultGlobal = vaultGlobal[position.vaultId];

        return
            _calcWethOwed(
                _vaultGlobal.globalWethFeesPerVTokenShareX128,
                position.wethFeesPerVTokenShareSnapshotX128,
                position.vTokenShareBalance
            ) + position.wethOwed;
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(
            ERC1155ReceiverUpgradeable,
            ERC721EnumerableUpgradeable,
            IERC165Upgradeable
        )
        returns (bool)
    {
        return
            interfaceId == type(ERC721PermitUpgradeable).interfaceId ||
            interfaceId == type(ERC1155ReceiverUpgradeable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        Position memory position = positions[tokenId];
        address vToken = nftxVaultFactory.vault(position.vaultId);

        uint256 vTokenBalance = (IERC20(vToken).balanceOf(address(this)) *
            position.vTokenShareBalance) /
            vaultGlobal[position.vaultId].totalVTokenShares;

        string memory vTokenSymbol = IERC20Metadata(vToken).symbol();

        return
            descriptor.tokenURI(
                tokenId,
                position.vaultId,
                vToken,
                vTokenSymbol,
                vTokenBalance,
                wethBalance(tokenId),
                position.timelockedUntil
            );
    }

    // =============================================================
    //                        INTERNAL HELPERS
    // =============================================================

    function _deposit(
        uint256 vaultId,
        uint256 amount,
        address recipient,
        VaultGlobal storage _vaultGlobal,
        uint256 preVTokenBalance,
        bool forceTimelock
    ) internal returns (uint256 positionId) {
        onlyOwnerIfPaused(0);

        _mint(recipient, (positionId = _nextId++));

        uint256 vTokenShares = _mintVTokenShares(
            _vaultGlobal,
            amount,
            preVTokenBalance
        );

        uint256 _timelock = timelock;
        positions[positionId] = Position({
            nonce: 0,
            vaultId: vaultId,
            timelockedUntil: forceTimelock ? block.timestamp + _timelock : 0,
            timelock: _timelock,
            vTokenTimelockedUntil: block.timestamp + VTOKEN_TIMELOCK,
            vTokenShareBalance: vTokenShares,
            wethFeesPerVTokenShareSnapshotX128: _vaultGlobal
                .globalWethFeesPerVTokenShareX128,
            wethOwed: 0
        });

        emit Deposit(vaultId, positionId, amount, forceTimelock);
    }

    function _increasePosition(
        uint256 positionId,
        Position storage position,
        uint256 vaultId,
        uint256 amount,
        uint256 preVTokenBalance,
        bool forceTimelock
    ) internal {
        onlyOwnerIfPaused(4);

        // only allow for positions created with just vTokens
        if (position.timelockedUntil > 0)
            revert PositionNotCreatedWithVTokens();

        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];

        // cache
        uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal
            .globalWethFeesPerVTokenShareX128;
        uint256 _preVTokenShareBalance = position.vTokenShareBalance;
        // account for weth fees accumulated till now
        position.wethOwed =
            _calcWethOwed(
                _globalWethFeesPerVTokenShareX128,
                position.wethFeesPerVTokenShareSnapshotX128,
                _preVTokenShareBalance
            ) +
            position.wethOwed;
        position
            .wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;

        position.vTokenShareBalance =
            _preVTokenShareBalance +
            _mintVTokenShares(_vaultGlobal, amount, preVTokenBalance);

        if (forceTimelock) {
            uint256 _timelock = timelock;
            position.timelockedUntil = block.timestamp + _timelock;
            position.timelock = _timelock;
        }
        position.vTokenTimelockedUntil = block.timestamp + VTOKEN_TIMELOCK;

        emit IncreasePosition(vaultId, positionId, amount);
    }

    function _mintVTokenShares(
        VaultGlobal storage _vaultGlobal,
        uint256 amount,
        uint256 preVTokenBalance
    ) internal returns (uint256 vTokenShares) {
        // cache
        uint256 _totalVTokenShares = _vaultGlobal.totalVTokenShares;
        if (_totalVTokenShares == 0) {
            if (amount < MINIMUM_LIQUIDITY) revert LiquidityBelowMinimum();
            unchecked {
                vTokenShares = amount - MINIMUM_LIQUIDITY;
            }
            // permanently locked to avoid front-running attack
            _totalVTokenShares = MINIMUM_LIQUIDITY;
        } else {
            vTokenShares = (amount * _totalVTokenShares) / preVTokenBalance;
        }
        if (vTokenShares == 0) revert ZeroVTokenShares();

        _vaultGlobal.totalVTokenShares = _totalVTokenShares + vTokenShares;
    }

    function _getTimelockedUntil(
        uint256 vaultId,
        uint256 _timelock
    ) internal view returns (uint256) {
        return
            timelockExcludeList.isExcluded(msg.sender, vaultId)
                ? 0
                : block.timestamp + _timelock;
    }

    function _calcWethOwed(
        uint256 globalWethFeesPerVTokenShareX128,
        uint256 positionWethFeesPerVTokenShareSnapshotX128,
        uint256 positionVTokenShareBalance
    ) internal pure returns (uint256 wethOwed) {
        wethOwed = FullMath.mulDiv(
            globalWethFeesPerVTokenShareX128 -
                positionWethFeesPerVTokenShareSnapshotX128,
            positionVTokenShareBalance,
            FixedPoint128.Q128
        );
    }

    function _getAndIncrementNonce(
        uint256 tokenId
    ) internal override returns (uint256) {
        return uint256(positions[tokenId].nonce++);
    }

    receive() external payable {}
}
