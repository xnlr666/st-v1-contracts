// SPDX-FileCopyrightText: 2023 Stake Together Labs <info@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import './Rewards.sol';

/// @custom:security-contact security@staketogether.app
abstract contract SETH is ERC20, ERC20Permit, Pausable, Ownable, ReentrancyGuard {
  Rewards public rewardsContract;

  constructor() ERC20('ST Staked Ether', 'SETH') ERC20Permit('ST Staked Ether') {
    _bootstrap();
  }

  event Bootstrap(address sender, uint256 balance);

  event MintShares(address indexed from, address indexed to, uint256 sharesAmount);
  event TransferShares(address indexed from, address indexed to, uint256 sharesAmount);
  event BurnShares(address indexed account, uint256 sharesAmount);

  mapping(address => uint256) private shares;
  uint256 public totalShares = 0;
  mapping(address => mapping(address => uint256)) private allowances;

  function _bootstrap() internal {
    address stakeTogether = address(this);
    uint256 balance = stakeTogether.balance;

    require(balance > 0, 'NON_ZERO_VALUE');

    emit Bootstrap(msg.sender, balance);

    _mintShares(stakeTogether, balance);
    _mintPoolShares(stakeTogether, stakeTogether, balance);

    setStakeTogetherFeeAddress(msg.sender);
    setOperatorFeeAddress(msg.sender);
    setValidatorModuleAddress(msg.sender);
    setPoolModuleAddress(msg.sender);
    setValidatorFeeAddress(msg.sender);
  }

  function pause() public onlyOwner {
    _pause();
  }

  function unpause() public onlyOwner {
    _unpause();
  }

  function contractBalance() public view returns (uint256) {
    return address(this).balance;
  }

  function totalSupply() public view override returns (uint256) {
    return totalPooledEther();
  }

  function balanceOf(address _account) public view override returns (uint256) {
    return pooledEthByShares(sharesOf(_account));
  }

  function sharesOf(address _account) public view returns (uint256) {
    return shares[_account];
  }

  function getSharesByPooledEth(uint256 _ethAmount) public view returns (uint256) {
    return Math.mulDiv(_ethAmount, totalShares, totalPooledEther());
  }

  function pooledEthByShares(uint256 _sharesAmount) public view returns (uint256) {
    return Math.mulDiv(_sharesAmount, totalPooledEther(), totalShares);
  }

  function transfer(address _to, uint256 _amount) public override returns (bool) {
    _transfer(msg.sender, _to, _amount);
    return true;
  }

  function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
    _spendAllowance(_from, msg.sender, _amount);
    _transfer(_from, _to, _amount);

    return true;
  }

  function transferShares(address _to, uint256 _sharesAmount) public returns (uint256) {
    _transferShares(msg.sender, _to, _sharesAmount);
    uint256 tokensAmount = pooledEthByShares(_sharesAmount);
    return tokensAmount;
  }

  function transferSharesFrom(
    address _from,
    address _to,
    uint256 _sharesAmount
  ) external returns (uint256) {
    uint256 tokensAmount = pooledEthByShares(_sharesAmount);
    _spendAllowance(_from, msg.sender, tokensAmount);
    _transferShares(_from, _to, _sharesAmount);
    return tokensAmount;
  }

  function allowance(address _account, address _spender) public view override returns (uint256) {
    return allowances[_account][_spender];
  }

  function approve(address _spender, uint256 _amount) public override returns (bool) {
    _approve(msg.sender, _spender, _amount);
    return true;
  }

  function increaseAllowance(address _spender, uint256 _addedValue) public override returns (bool) {
    _approve(msg.sender, _spender, allowances[msg.sender][_spender] + _addedValue);
    return true;
  }

  function decreaseAllowance(address _spender, uint256 _subtractedValue) public override returns (bool) {
    uint256 currentAllowance = allowances[msg.sender][_spender];
    require(currentAllowance >= _subtractedValue, 'ALLOWANCE_BELOW_ZERO');
    _approve(msg.sender, _spender, currentAllowance - _subtractedValue);
    return true;
  }

  function totalPooledEther() public view virtual returns (uint256);

  function _approve(address _account, address _spender, uint256 _amount) internal override {
    require(_account != address(0), 'APPROVE_FROM_ZERO_ADDR');
    require(_spender != address(0), 'APPROVE_TO_ZERO_ADDR');

    allowances[_account][_spender] = _amount;
    emit Approval(_account, _spender, _amount);
  }

  function _mintShares(address _to, uint256 _sharesAmount) internal whenNotPaused {
    require(_to != address(0), 'MINT_TO_ZERO_ADDR');

    shares[_to] = shares[_to] + _sharesAmount;
    totalShares += _sharesAmount;

    emit MintShares(address(0), _to, _sharesAmount);
  }

  function _burnShares(address _account, uint256 _sharesAmount) internal whenNotPaused {
    require(_account != address(0), 'BURN_FROM_ZERO_ADDR');
    require(_sharesAmount <= shares[_account], 'BALANCE_EXCEEDED');

    shares[_account] = shares[_account] - _sharesAmount;
    totalShares -= _sharesAmount;

    emit BurnShares(_account, _sharesAmount);
  }

  function _transfer(address _from, address _to, uint256 _amount) internal override {
    uint256 _sharesToTransfer = getSharesByPooledEth(_amount);
    _transferShares(_from, _to, _sharesToTransfer);
    _transferDelegationShares(_from, _to, _sharesToTransfer);
    emit Transfer(_from, _to, _amount);
  }

  function _transferShares(address _from, address _to, uint256 _sharesAmount) internal whenNotPaused {
    require(_from != address(0), 'TRANSFER_FROM_ZERO_ADDR');
    require(_to != address(0), 'TRANSFER_TO_ZERO_ADDR');
    require(_to != address(this), 'TRANSFER_TO_CETH_CONTRACT');
    require(_sharesAmount <= shares[_from], 'BALANCE_EXCEEDED');

    shares[_from] = shares[_from] - _sharesAmount;
    shares[_to] = shares[_to] + _sharesAmount;

    emit TransferShares(_from, _to, _sharesAmount);
  }

  function _spendAllowance(address _account, address _spender, uint256 _amount) internal override {
    uint256 currentAllowance = allowances[_account][_spender];
    if (currentAllowance != ~uint256(0)) {
      require(currentAllowance >= _amount, 'ALLOWANCE_EXCEEDED');
      _approve(_account, _spender, currentAllowance - _amount);
    }
  }

  /*****************
   ** DELEGATIONS **
   *****************/

  uint256 public maxDelegations = 64;
  mapping(address => uint256) private poolShares;
  uint256 public totalPoolShares = 0;
  mapping(address => mapping(address => uint256)) private delegationsShares;
  mapping(address => address[]) private delegates;
  mapping(address => mapping(address => bool)) private isDelegator;

  event MintPoolShares(
    address indexed from,
    address indexed to,
    address indexed pool,
    uint256 sharesAmount
  );

  event TransferPoolShares(
    address indexed from,
    address indexed to,
    address indexed pool,
    uint256 sharesAmount
  );

  event BurnPoolShares(address indexed from, address indexed pool, uint256 sharesAmount);

  function poolSharesOf(address _account) public view returns (uint256) {
    return poolShares[_account];
  }

  function delegationSharesOf(address _account, address _pool) public view returns (uint256) {
    return delegationsShares[_account][_pool];
  }

  function transferPoolShares(address _from, address _to, uint256 _sharesAmount) external {
    _transferPoolShares(msg.sender, _from, _to, _sharesAmount);
  }

  function _mintPoolShares(address _to, address _pool, uint256 _sharesAmount) internal whenNotPaused {
    require(_to != address(0), 'MINT_TO_ZERO_ADDR');
    require(_pool != address(0), 'MINT_TO_ZERO_ADDR');
    require(isPool(_pool), 'ONLY_CAN_DELEGATE_TO_POOL');
    require(delegates[_to].length < maxDelegations, 'MAX_DELEGATIONS_REACHED');

    poolShares[_pool] += _sharesAmount;
    delegationsShares[_to][_pool] += _sharesAmount;
    totalPoolShares += _sharesAmount;

    if (!isDelegator[_to][_pool]) {
      delegates[_to].push(_pool);
      isDelegator[_to][_pool] = true;
    }

    emit MintPoolShares(address(0), _to, _pool, _sharesAmount);
  }

  function _burnPoolShares(address _from, address _pool, uint256 _sharesAmount) internal whenNotPaused {
    require(_from != address(0), 'BURN_FROM_ZERO_ADDR');
    require(_pool != address(0), 'BURN_FROM_ZERO_ADDR');
    require(isPool(_pool), 'ONLY_CAN_BURN_FROM_POOL');

    poolShares[_pool] -= _sharesAmount;
    delegationsShares[_from][_pool] -= _sharesAmount;
    totalPoolShares -= _sharesAmount;

    if (delegationsShares[_from][_pool] == 0) {
      isDelegator[_from][_pool] = false;
    }

    emit BurnPoolShares(_from, _pool, _sharesAmount);
  }

  function _transferDelegationShares(
    address _from,
    address _to,
    uint256 _sharesToTransfer
  ) internal whenNotPaused {
    require(_sharesToTransfer <= sharesOf(_from), 'TRANSFER_EXCEEDS_BALANCE');

    for (uint256 i = 0; i < delegates[_from].length; i++) {
      address pool = delegates[_from][i];
      uint256 delegationSharesToTransfer = Math.mulDiv(
        delegationSharesOf(_from, pool),
        _sharesToTransfer,
        sharesOf(_from)
      );

      delegationsShares[_from][pool] -= delegationSharesToTransfer;

      if (!isDelegator[_to][pool]) {
        require(delegates[_to].length < maxDelegations, 'MAX_DELEGATIONS_REACHED');
        delegates[_to].push(pool);
        isDelegator[_to][pool] = true;
      }

      delegationsShares[_to][pool] += delegationSharesToTransfer;

      if (delegationSharesOf(_from, pool) == 0) {
        isDelegator[_from][pool] = false;
      }

      emit TransferPoolShares(_from, _to, pool, delegationSharesToTransfer);
    }
  }

  function _transferPoolShares(
    address _account,
    address _from,
    address _to,
    uint256 _sharesAmount
  ) internal whenNotPaused {
    require(_from != address(0), 'TRANSFER_FROM_ZERO_ADDR');
    require(_to != address(0), 'TRANSFER_TO_ZERO_ADDR');
    require(_to != address(this), 'TRANSFER_TO_SETH_CONTRACT');
    require(isPool(_to), 'ONLY_CAN_STAKE_TO_POOL');

    require(_sharesAmount <= delegationsShares[_account][_from], 'BALANCE_EXCEEDED');

    poolShares[_from] -= _sharesAmount;
    delegationsShares[_account][_from] -= _sharesAmount;

    poolShares[_to] += _sharesAmount;
    delegationsShares[_account][_to] += _sharesAmount;

    emit TransferPoolShares(_account, _from, _to, _sharesAmount);
  }

  /*****************
   ** ADDRESSES **
   *****************/

  address public stakeTogetherFeeAddress;
  address public operatorFeeAddress;
  address public validatorFeeAddress;
  address public liquidityFeeAddress;
  address public newPoolFeeAddress;
  address public validatorModuleAddress;
  address public poolModuleAddress;

  event SetStakeTogetherFeeAddress(address indexed to);
  event SetOperatorFeeAddress(address indexed to);
  event SetValidatorFeeAddress(address indexed to);
  event SetLiquidityFeeAddress(address indexed to);
  event SetNewPoolFeeAddress(address indexed to);
  event SetValidatorModuleAddress(address indexed to);
  event SetPoolModuleAddress(address indexed to);

  function setStakeTogetherFeeAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    stakeTogetherFeeAddress = _to;
    emit SetStakeTogetherFeeAddress(_to);
  }

  function setOperatorFeeAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    operatorFeeAddress = _to;
    emit SetOperatorFeeAddress(_to);
  }

  function setValidatorFeeAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    validatorFeeAddress = _to;
    emit SetValidatorFeeAddress(_to);
  }

  function setLiquidityFeeAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    liquidityFeeAddress = _to;
    emit SetLiquidityFeeAddress(_to);
  }

  function setPoolFeeAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    newPoolFeeAddress = _to;
    emit SetNewPoolFeeAddress(_to);
  }

  function setValidatorModuleAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    validatorModuleAddress = _to;
    emit SetValidatorModuleAddress(_to);
  }

  function setPoolModuleAddress(address _to) public onlyOwner {
    require(_to != address(0), 'NON_ZERO_ADDR');
    poolModuleAddress = _to;
    emit SetPoolModuleAddress(_to);
  }

  function _isStakeTogetherFeeAddress(address account) internal view returns (bool) {
    return address(stakeTogetherFeeAddress) == account;
  }

  function _isOperatorFeeAddress(address account) internal view returns (bool) {
    return address(operatorFeeAddress) == account;
  }

  /*****************
   ** FEES **
   *****************/

  uint256 public basisPoints = 1 ether;
  uint256 public stakeTogetherFee = 0.03 ether;
  uint256 public operatorFee = 0.03 ether;
  uint256 public poolFee = 0.03 ether;
  uint256 public newPoolFee = 0.1 ether;
  uint256 public validatorFee = 0.001 ether;

  event SetStakeTogetherFee(uint256 fee);
  event SetPoolFee(uint256 fee);
  event SetOperatorFee(uint256 fee);
  event SetNewPoolFee(uint256 newPoolFee);
  event SetValidatorFee(uint256 newFee);

  function setStakeTogetherFee(uint256 _fee) external onlyOwner {
    stakeTogetherFee = _fee;
    emit SetStakeTogetherFee(_fee);
  }

  function setPoolFee(uint256 _fee) external onlyOwner {
    poolFee = _fee;
    emit SetPoolFee(_fee);
  }

  function setOperatorFee(uint256 _fee) external onlyOwner {
    operatorFee = _fee;
    emit SetOperatorFee(_fee);
  }

  function setNewPoolFee(uint256 _newFee) external onlyOwner {
    newPoolFee = _newFee;
    emit SetNewPoolFee(_newFee);
  }

  function setValidatorFee(uint256 _newFee) external onlyOwner {
    validatorFee = _newFee;
    emit SetValidatorFee(_newFee);
  }

  /*****************
   ** REWARDS **
   *****************/

  modifier onlyRewardsContract() {
    require(msg.sender == address(rewardsContract), 'ONLY_REWARDS_CONTACT');
    _;
  }

  struct Reward {
    address recipient;
    uint256 shares;
    uint256 amount;
  }

  enum RewardType {
    StakeTogether,
    Operator,
    Pool
  }

  uint256 public beaconBalance = 0;

  event MintRewards(uint256 blockNumber, address indexed to, uint256 sharesAmount, RewardType rewardType);
  event MintLoss(uint256 blockNumber, uint256 amount);

  function mintRewards(
    uint256 blockNumber,
    address rewardAddress,
    uint256 sharesAmount
  ) external payable nonReentrant onlyRewardsContract {
    _mintShares(rewardAddress, sharesAmount);
    _mintPoolShares(rewardAddress, rewardAddress, sharesAmount);

    if (rewardAddress == stakeTogetherFeeAddress) {
      emit MintRewards(blockNumber, rewardAddress, sharesAmount, RewardType.StakeTogether);
    } else if (rewardAddress == operatorFeeAddress) {
      emit MintRewards(blockNumber, rewardAddress, sharesAmount, RewardType.Operator);
    } else {
      emit MintRewards(blockNumber, rewardAddress, sharesAmount, RewardType.Pool);
    }
  }

  function mintLoss(uint256 _blockNumber, uint256 _lossAmount) external nonReentrant onlyRewardsContract {
    beaconBalance -= _lossAmount;
    require(totalPooledEther() - _lossAmount > 0, 'NEGATIVE_TOTAL_POOLED_ETHER_BALANCE');
    emit MintLoss(_blockNumber, _lossAmount);
  }

  /*****************
   ** POOLS **
   *****************/

  uint256 public maxPools = 100000;
  address[] private pools;

  modifier onlyPoolModule() {
    require(msg.sender == poolModuleAddress, 'ONLY_POOL_MODULE');
    _;
  }

  event AddPool(address account);
  event RemovePool(address account);
  event SetMaxPools(uint256 maxPools);

  function getPools() public view returns (address[] memory) {
    return pools;
  }

  function setMaxPools(uint256 _maxPools) external onlyOwner {
    maxPools = _maxPools;
    emit SetMaxPools(_maxPools);
  }

  function addPool(address _pool) external payable onlyPoolModule {
    require(_pool != address(0), 'ZERO_ADDR');
    require(!isPool(_pool), 'NON_POOL');
    require(!_isStakeTogetherFeeAddress(_pool), 'IS_STAKE_TOGETHER_FEE_RECIPIENT');
    require(!_isOperatorFeeAddress(_pool), 'IS_OPERATOR_FEE_RECIPIENT');
    require(pools.length < maxPools, 'MAX_POOLS_REACHED');

    pools.push(_pool);
    emit AddPool(_pool);

    if (msg.sender != owner() && msg.sender != poolModuleAddress) {
      require(msg.value >= newPoolFee, 'NOT_ENOUGH_POOL_CREATION_FEE');
      payable(newPoolFeeAddress).transfer(newPoolFee);
    }
  }

  function removePool(address _pool) external onlyPoolModule {
    require(isPool(_pool), 'POOL_NOT_FOUND');

    for (uint256 i = 0; i < pools.length; i++) {
      if (pools[i] == _pool) {
        pools[i] = pools[pools.length - 1];
        pools.pop();
        break;
      }
    }
    emit RemovePool(_pool);
  }

  function isPool(address _pool) internal view returns (bool) {
    if (_pool == address(this)) {
      return true;
    }

    for (uint256 i = 0; i < pools.length; i++) {
      if (pools[i] == _pool) {
        return true;
      }
    }
    return false;
  }
}
