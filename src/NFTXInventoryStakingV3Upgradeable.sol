contract NFTXInventoryStakingV3Upgradeable is INFTXInventoryStakingV3, ERC721PermitUpgradeable, ERC1155HolderUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using Strings for uint256;
    uint256 public constant override MINIMUM_LIQUIDITY = 1_000;
    uint256 private constant VTOKEN_TIMELOCK = 1 hours;
    IWETH9 public immutable override WETH;
    IPermitAllowanceTransfer public immutable override PERMIT2;
    INFTXVaultFactoryV3 public immutable override nftxVaultFactory;
    ITimelockExcludeList public override timelockExcludeList;
    uint256 constant MAX_TIMELOCK = 14 days;
    uint256 constant MAX_EARLY_WITHDRAW_PENALTY = 1 ether;
    uint256 constant BASE = 1 ether;
    uint256 private _nextId;
    uint256 public override timelock;
    uint256 public override earlyWithdrawPenaltyInWei;
    mapping(uint256 => Position) public override positions;
    mapping(uint256 => VaultGlobal) public override vaultGlobal;
    InventoryStakingDescriptor public override descriptor;
    constructor(IWETH9 WETH_, IPermitAllowanceTransfer PERMIT2_, INFTXVaultFactoryV3 nftxVaultFactory_) {
        WETH = WETH_;
        PERMIT2 = PERMIT2_;
        nftxVaultFactory = nftxVaultFactory_;
    }
    function __NFTXInventoryStaking_init(uint256 timelock_, uint256 earlyWithdrawPenaltyInWei_, ITimelockExcludeList timelockExcludeList_, InventoryStakingDescriptor descriptor_) external override initializer {
        __ERC721PermitUpgradeable_init("NFTX Inventory Staking", "xNFT", "1");
        __Pausable_init();
        __ReentrancyGuard_init();
        if (timelock_ > MAX_TIMELOCK) revert TimelockTooLong();
        if (earlyWithdrawPenaltyInWei_ > MAX_EARLY_WITHDRAW_PENALTY) revert InvalidEarlyWithdrawPenalty();
        timelock = timelock_;
        earlyWithdrawPenaltyInWei = earlyWithdrawPenaltyInWei_;
        timelockExcludeList = timelockExcludeList_;
        descriptor = descriptor_;
        _nextId = 1;
    }
    function deposit(uint256 vaultId, uint256 amount, address recipient, bytes calldata encodedPermit2, bool viaPermit2, bool forceTimelock) external override returns (uint256 positionId) {
        address vToken = nftxVaultFactory.vault(vaultId);
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        uint256 preVTokenBalance = IERC20(vToken).balanceOf(address(this));
        if (viaPermit2) {
            if (encodedPermit2.length > 0) {
                (address _owner, IPermitAllowanceTransfer.PermitSingle memory permitSingle, bytes memory signature) = abi.decode(encodedPermit2, (address, IPermitAllowanceTransfer.PermitSingle, bytes));
                PERMIT2.permit(_owner, permitSingle, signature);
            }
            PERMIT2.transferFrom(msg.sender, address(this), SafeCast.toUint160(amount), address(vToken));
        } else {
            IERC20(vToken).transferFrom(msg.sender, address(this), amount);
        }
        return _deposit(vaultId, amount, recipient, _vaultGlobal, preVTokenBalance, forceTimelock);
    }
    function depositWithNFT(uint256 vaultId, uint256[] calldata tokenIds, uint256[] calldata amounts, address recipient) external returns (uint256 positionId) {
        onlyOwnerIfPaused(1);
        address vToken = nftxVaultFactory.vault(vaultId);
        uint256 preVTokenBalance = IERC20(vToken).balanceOf(address(this));
        uint256 amount;
        {
            address assetAddress = INFTXVaultV3(vToken).assetAddress();
            if (!INFTXVaultV3(vToken).is1155()) {
                TransferLib.transferFromERC721(assetAddress, address(vToken), tokenIds);
            } else {
                IERC1155(assetAddress).safeBatchTransferFrom(msg.sender, address(this), tokenIds, amounts, "");
                IERC1155(assetAddress).setApprovalForAll(address(vToken), true);
            }
            amount = INFTXVaultV3(vToken).mint(tokenIds, amounts, msg.sender, address(this));
        }
        _mint(recipient, (positionId = _nextId++));
        {
            VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
            uint256 vTokenShares = _mintVTokenShares(_vaultGlobal, amount, preVTokenBalance);
            uint256 _timelock = timelock;
            positions[positionId] = Position({nonce: 0, vaultId: vaultId, timelockedUntil: _getTimelockedUntil(vaultId, _timelock), timelock: _timelock, vTokenTimelockedUntil: 0, vTokenShareBalance: vTokenShares, wethFeesPerVTokenShareSnapshotX128: _vaultGlobal.globalWethFeesPerVTokenShareX128, wethOwed: 0});
        }
        emit DepositWithNFT(vaultId, positionId, tokenIds, amounts);
    }
    function increasePosition(uint256 positionId, uint256 amount, bytes calldata encodedPermit2, bool viaPermit2, bool forceTimelock) external {
        if (ownerOf(positionId) != msg.sender) revert NotPositionOwner();
        Position storage position = positions[positionId];
        uint256 vaultId = position.vaultId;
        address vToken = nftxVaultFactory.vault(vaultId);
        uint256 preVTokenBalance = IERC20(vToken).balanceOf(address(this));
        if (viaPermit2) {
            if (encodedPermit2.length > 0) {
                (address _owner, IPermitAllowanceTransfer.PermitSingle memory permitSingle, bytes memory signature) = abi.decode(encodedPermit2, (address, IPermitAllowanceTransfer.PermitSingle, bytes));
                PERMIT2.permit(_owner, permitSingle, signature);
            }
            PERMIT2.transferFrom(msg.sender, address(this), SafeCast.toUint160(amount), address(vToken));
        } else {
            IERC20(vToken).transferFrom(msg.sender, address(this), amount);
        }
        return _increasePosition(positionId, position, vaultId, amount, preVTokenBalance, forceTimelock);
    }
    function withdraw(uint256 positionId, uint256 vTokenShares, uint256[] calldata nftIds, uint256 vTokenPremiumLimit) external payable override nonReentrant {
        onlyOwnerIfPaused(2);
        if (ownerOf(positionId) != msg.sender) revert NotPositionOwner();
        address vToken;
        uint256 vTokenOwed;
        uint256 wethOwed;
        uint256 _timelockedUntil;
        {
            Position storage position = positions[positionId];
            if (block.timestamp <= position.vTokenTimelockedUntil) revert Timelocked();
            uint256 positionVTokenShareBalance = position.vTokenShareBalance;
            if (positionVTokenShareBalance < vTokenShares) revert InsufficientVTokenShares();
            VaultGlobal storage _vaultGlobal;
            {
                uint256 vaultId = position.vaultId;
                _vaultGlobal = vaultGlobal[vaultId];
                vToken = nftxVaultFactory.vault(vaultId);
            }
            uint256 _totalVTokenShares = _vaultGlobal.totalVTokenShares;
            vTokenOwed = (IERC20(vToken).balanceOf(address(this)) * vTokenShares) / _totalVTokenShares;
            {
                uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal.globalWethFeesPerVTokenShareX128;
                {
                    wethOwed = _calcWethOwed(_globalWethFeesPerVTokenShareX128, position.wethFeesPerVTokenShareSnapshotX128, positionVTokenShareBalance) + position.wethOwed;
                }
                position.wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
                position.wethOwed = 0;
            }
            _timelockedUntil = position.timelockedUntil;
            if (block.timestamp <= _timelockedUntil) {
                uint256 vTokenPenalty = ((_timelockedUntil - block.timestamp) * vTokenOwed * earlyWithdrawPenaltyInWei) / (position.timelock * BASE);
                vTokenOwed -= vTokenPenalty;
            }
            _vaultGlobal.totalVTokenShares = _totalVTokenShares - vTokenShares;
            position.vTokenShareBalance -= vTokenShares;
        }
        uint256 nftCount = nftIds.length;
        if (nftCount > 0) {
            uint256 requiredVTokens = nftCount * BASE;
            if (vTokenOwed < requiredVTokens) revert InsufficientVTokens();
            {
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
            IERC20(vToken).transfer(msg.sender, vTokenOwed);
        }
        WETH.transfer(msg.sender, wethOwed);
        uint256 ethResidue = address(this).balance;
        TransferLib.transferETH(msg.sender, ethResidue);
        emit Withdraw(positionId, vTokenShares, vTokenOwed, wethOwed);
    }
    function combinePositions(uint256 parentPositionId, uint256[] calldata childPositionIds) external override {
        if (ownerOf(parentPositionId) != msg.sender) revert NotPositionOwner();
        Position storage parentPosition = positions[parentPositionId];
        uint256 parentVaultId = parentPosition.vaultId;
        VaultGlobal storage _vaultGlobal = vaultGlobal[parentVaultId];
        if (block.timestamp <= parentPosition.timelockedUntil || block.timestamp <= parentPosition.vTokenTimelockedUntil) revert Timelocked();
        uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal.globalWethFeesPerVTokenShareX128;
        uint256 _parentVTokenShareBalance = parentPosition.vTokenShareBalance;
        uint256 netWethOwed = _calcWethOwed(_globalWethFeesPerVTokenShareX128, parentPosition.wethFeesPerVTokenShareSnapshotX128, _parentVTokenShareBalance);
        uint256 childrenPositionsCount = childPositionIds.length;
        for (uint256 i; i < childrenPositionsCount; ) {
            if (childPositionIds[i] == parentPositionId) revert ParentChildSame();
            if (ownerOf(childPositionIds[i]) != msg.sender) revert NotPositionOwner();
            Position storage childPosition = positions[childPositionIds[i]];
            if (block.timestamp <= childPosition.timelockedUntil || block.timestamp <= childPosition.vTokenTimelockedUntil) revert Timelocked();
            if (childPosition.vaultId != parentVaultId) revert VaultIdMismatch();
            uint256 _childVTokenShareBalance = childPosition.vTokenShareBalance;
            netWethOwed += _calcWethOwed(_globalWethFeesPerVTokenShareX128, childPosition.wethFeesPerVTokenShareSnapshotX128, _childVTokenShareBalance) + childPosition.wethOwed;
            _parentVTokenShareBalance += _childVTokenShareBalance;
            childPosition.vTokenShareBalance = 0;
            childPosition.wethOwed = 0;
            unchecked {
                ++i;
            }
        }
        parentPosition.wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
        parentPosition.vTokenShareBalance = _parentVTokenShareBalance;
        parentPosition.wethOwed += netWethOwed;
        emit CombinePositions(parentPositionId, childPositionIds);
    }
    function collectWethFees(uint256[] calldata positionIds) external {
        onlyOwnerIfPaused(3);
        uint256 totalWethOwed;
        uint256 wethOwed;
        uint256 len = positionIds.length;
        for (uint256 i; i < len; ) {
            if (ownerOf(positionIds[i]) != msg.sender) revert NotPositionOwner();
            Position storage position = positions[positionIds[i]];
            VaultGlobal storage _vaultGlobal = vaultGlobal[position.vaultId];
            uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal.globalWethFeesPerVTokenShareX128;
            wethOwed = _calcWethOwed(_globalWethFeesPerVTokenShareX128, position.wethFeesPerVTokenShareSnapshotX128, position.vTokenShareBalance) + position.wethOwed;
            totalWethOwed += wethOwed;
            position.wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
            position.wethOwed = 0;
            emit CollectWethFees(positionIds[i], wethOwed);
            unchecked {
                ++i;
            }
        }
        WETH.transfer(msg.sender, totalWethOwed);
    }
    function receiveWethRewards(uint256 vaultId, uint256 wethAmount) external override returns (bool rewardsDistributed) {
        if (msg.sender != nftxVaultFactory.feeDistributor()) revert SenderNotFeeDistributor();
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        if (_vaultGlobal.totalVTokenShares == 0) {
            return false;
        }
        rewardsDistributed = true;
        WETH.transferFrom(msg.sender, address(this), wethAmount);
        _vaultGlobal.globalWethFeesPerVTokenShareX128 += FullMath.mulDiv(wethAmount, FixedPoint128.Q128, _vaultGlobal.totalVTokenShares);
    }
    function setTimelock(uint256 timelock_) external override onlyOwner {
        if (timelock_ > MAX_TIMELOCK) revert TimelockTooLong();
        timelock = timelock_;
        emit UpdateTimelock(timelock_);
    }
    function setEarlyWithdrawPenalty(uint256 earlyWithdrawPenaltyInWei_) external override onlyOwner {
        if (earlyWithdrawPenaltyInWei_ > MAX_EARLY_WITHDRAW_PENALTY) revert InvalidEarlyWithdrawPenalty();
        earlyWithdrawPenaltyInWei = earlyWithdrawPenaltyInWei_;
        emit UpdateEarlyWithdrawPenalty(earlyWithdrawPenaltyInWei_);
    }
    function setDescriptor(InventoryStakingDescriptor descriptor_) external override onlyOwner {
        if (address(descriptor_) == address(0)) revert ZeroAddress();
        descriptor = descriptor_;
    }
    function pricePerShareVToken(uint256 vaultId) external view override returns (uint256) {
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        address vToken = nftxVaultFactory.vault(vaultId);
        return (IERC20(vToken).balanceOf(address(this)) * BASE) / _vaultGlobal.totalVTokenShares;
    }
    function wethBalance(uint256 positionId) public view override returns (uint256) {
        Position memory position = positions[positionId];
        VaultGlobal memory _vaultGlobal = vaultGlobal[position.vaultId];
        return _calcWethOwed(_vaultGlobal.globalWethFeesPerVTokenShareX128, position.wethFeesPerVTokenShareSnapshotX128, position.vTokenShareBalance) + position.wethOwed;
    }
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155ReceiverUpgradeable, ERC721EnumerableUpgradeable, IERC165Upgradeable) returns (bool) {
        return interfaceId == type(ERC721PermitUpgradeable).interfaceId || interfaceId == type(ERC1155ReceiverUpgradeable).interfaceId || super.supportsInterface(interfaceId);
    }
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        Position memory position = positions[tokenId];
        address vToken = nftxVaultFactory.vault(position.vaultId);
        uint256 vTokenBalance = (IERC20(vToken).balanceOf(address(this)) * position.vTokenShareBalance) / vaultGlobal[position.vaultId].totalVTokenShares;
        string memory vTokenSymbol = IERC20Metadata(vToken).symbol();
        return descriptor.tokenURI(tokenId, position.vaultId, vToken, vTokenSymbol, vTokenBalance, wethBalance(tokenId), position.timelockedUntil);
    }
    function _deposit(uint256 vaultId, uint256 amount, address recipient, VaultGlobal storage _vaultGlobal, uint256 preVTokenBalance, bool forceTimelock) internal returns (uint256 positionId) {
        onlyOwnerIfPaused(0);
        _mint(recipient, (positionId = _nextId++));
        uint256 vTokenShares = _mintVTokenShares(_vaultGlobal, amount, preVTokenBalance);
        uint256 _timelock = timelock;
        positions[positionId] = Position({nonce: 0, vaultId: vaultId, timelockedUntil: forceTimelock ? block.timestamp + _timelock : 0, timelock: _timelock, vTokenTimelockedUntil: block.timestamp + VTOKEN_TIMELOCK, vTokenShareBalance: vTokenShares, wethFeesPerVTokenShareSnapshotX128: _vaultGlobal.globalWethFeesPerVTokenShareX128, wethOwed: 0});
        emit Deposit(vaultId, positionId, amount, forceTimelock);
    }
    function _increasePosition(uint256 positionId, Position storage position, uint256 vaultId, uint256 amount, uint256 preVTokenBalance, bool forceTimelock) internal {
        onlyOwnerIfPaused(4);
        if (position.timelockedUntil > 0) revert PositionNotCreatedWithVTokens();
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        uint256 _globalWethFeesPerVTokenShareX128 = _vaultGlobal.globalWethFeesPerVTokenShareX128;
        uint256 _preVTokenShareBalance = position.vTokenShareBalance;
        position.wethOwed = _calcWethOwed(_globalWethFeesPerVTokenShareX128, position.wethFeesPerVTokenShareSnapshotX128, _preVTokenShareBalance) + position.wethOwed;
        position.wethFeesPerVTokenShareSnapshotX128 = _globalWethFeesPerVTokenShareX128;
        position.vTokenShareBalance = _preVTokenShareBalance + _mintVTokenShares(_vaultGlobal, amount, preVTokenBalance);
        if (forceTimelock) {
            uint256 _timelock = timelock;
            position.timelockedUntil = block.timestamp + _timelock;
            position.timelock = _timelock;
        }
        position.vTokenTimelockedUntil = block.timestamp + VTOKEN_TIMELOCK;
        emit IncreasePosition(vaultId, positionId, amount);
    }
    function _mintVTokenShares(VaultGlobal storage _vaultGlobal, uint256 amount, uint256 preVTokenBalance) internal returns (uint256 vTokenShares) {
        uint256 _totalVTokenShares = _vaultGlobal.totalVTokenShares;
        if (_totalVTokenShares == 0) {
            if (amount < MINIMUM_LIQUIDITY) revert LiquidityBelowMinimum();
            unchecked {
                vTokenShares = amount - MINIMUM_LIQUIDITY;
            }
            _totalVTokenShares = MINIMUM_LIQUIDITY;
        } else {
            vTokenShares = (amount * _totalVTokenShares) / preVTokenBalance;
        }
        if (vTokenShares == 0) revert ZeroVTokenShares();
        _vaultGlobal.totalVTokenShares = _totalVTokenShares + vTokenShares;
    }
    function _getTimelockedUntil(uint256 vaultId, uint256 _timelock) internal view returns (uint256) {
        return timelockExcludeList.isExcluded(msg.sender, vaultId) ? 0 : block.timestamp + _timelock;
    }
    function _calcWethOwed(uint256 globalWethFeesPerVTokenShareX128, uint256 positionWethFeesPerVTokenShareSnapshotX128, uint256 positionVTokenShareBalance) internal pure returns (uint256 wethOwed) {
        wethOwed = FullMath.mulDiv(globalWethFeesPerVTokenShareX128 - positionWethFeesPerVTokenShareSnapshotX128, positionVTokenShareBalance, FixedPoint128.Q128);
    }
    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        return uint256(positions[tokenId].nonce++);
    }
    receive() external payable {}
}
