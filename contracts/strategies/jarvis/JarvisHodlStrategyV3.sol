//SPDX-License-Identifier: Unlicense
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "./interface/IElysianFields.sol";

import "../../base/interface/IVault.sol";
import "../../base/interface/kyber/IDMMRouter02.sol";
import "../../base/interface/kyber/IDMMPool.sol";
import "../../base/interface/kyber/IKyberZap.sol";

import "../../base/upgradability/BaseUpgradeableStrategy.sol";

import "../../base/PotPool.sol";

contract JarvisHodlStrategyV3 is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant kyberRouter = address(0x546C79662E028B661dFB4767664d0273184E4dD1);
  address public constant kyberZapper = address(0x83D4908c1B4F9Ca423BEE264163BC1d50F251c31);
  address public constant msig = address(0x39cC360806b385C96969ce9ff26c23476017F652);
  uint256 internal constant maxUint = uint256(~0);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _POOLID_SLOT = 0x3fd729bfa2e28b7806b03a6e014729f59477b530f995be4d51defc9dad94810b;
  bytes32 internal constant _HODLVAULT_SLOT = 0xc26d330f887c749cb38ae7c37873ff08ac4bba7aec9113c82d48a0cf6cc145f2;
  bytes32 internal constant _POTPOOL_SLOT = 0x7f4b50847e7d7a4da6a6ea36bfb188c77e9f093697337eb9a876744f926dd014;
  bytes32 internal constant _REWARD_LP_SLOT = 0x48141e8830aff32be47daedfc211bdc62d1652246e1c94ca6dfd96128ee259d2;
  bytes32 internal constant _REWARD_LP_TOKEN1_SLOT = 0x39bbed0fce4dadfae510b0ff92e23dc8458ac86daafb72558e64503559b640ed;

  constructor() public BaseUpgradeableStrategy() {
    assert(_POOLID_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.poolId")) - 1));
    assert(_HODLVAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.hodlVault")) - 1));
    assert(_POTPOOL_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.potPool")) - 1));
    assert(_REWARD_LP_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.rewardLp")) - 1));
    assert(_REWARD_LP_TOKEN1_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.rewardLpToken1")) - 1));
  }

  function initializeBaseStrategy(
    address __storage,
    address _underlying,
    address _vault,
    address _rewardPool,
    address _rewardToken,
    uint256 _poolId,
    address _rewardLp,
    address _hodlVault,
    address _potPool
  ) public initializer {
    require(_rewardPool != address(0), "reward pool is empty");

    BaseUpgradeableStrategy.initialize(
      __storage,
      _underlying,
      _vault,
      _rewardPool,
      _rewardToken,
      80, // profit sharing numerator
      1000, // profit sharing denominator
      true, // sell
      1e15, // sell floor
      12 hours // implementation change delay
    );

    address _lpt;
    (_lpt,,,) = IElysianFields(_rewardPool).poolInfo(_poolId);
    require(_lpt == _underlying, "Pool Info does not match underlying");

    _setPoolId(_poolId);
    setAddress(_REWARD_LP_SLOT, _rewardLp);
    setAddress(_HODLVAULT_SLOT, _hodlVault);
    setAddress(_POTPOOL_SLOT, _potPool);

    address token0 = IDMMPool(_rewardLp).token0();
    address token1 = IDMMPool(_rewardLp).token1();
    require(token0 == _rewardToken || token1 == _rewardToken, "One of the underlying DMM pool token is not equal to the rewardToken");

    address rewardLpToken1 = (token0 == _rewardToken) ? token1 : token0;

    setAddress(_REWARD_LP_TOKEN1_SLOT, rewardLpToken1);
  }

  /*///////////////////////////////////////////////////////////////
                  STORAGE SETTER AND GETTER
  //////////////////////////////////////////////////////////////*/

  function setHodlVault(address _value) public onlyGovernance {
    require(hodlVault() == address(0), "Hodl vault already set");
    setAddress(_HODLVAULT_SLOT, _value);
  }

  function hodlVault() public view returns (address) {
    return getAddress(_HODLVAULT_SLOT);
  }

  function setPotPool(address _value) public onlyGovernance {
    require(potPool() == address(0), "PotPool already set");
    setAddress(_POTPOOL_SLOT, _value);
  }

  function potPool() public view returns (address) {
    return getAddress(_POTPOOL_SLOT);
  }

  function setRewardLp(address _value) public onlyGovernance {
    setAddress(_REWARD_LP_SLOT, _value);
  }

  function rewardLp() public view returns (address) {
    return getAddress(_REWARD_LP_SLOT);
  }

  function setRewardLpToken1(address _value) public onlyGovernance {
    setAddress(_REWARD_LP_TOKEN1_SLOT, _value);
  }

  function rewardLpToken1() public view returns (address) {
    return getAddress(_REWARD_LP_TOKEN1_SLOT);
  }

    // masterchef rewards pool ID
  function _setPoolId(uint256 _value) internal {
    setUint256(_POOLID_SLOT, _value);
  }

  function poolId() public view returns (uint256) {
    return getUint256(_POOLID_SLOT);
  }

  /*///////////////////////////////////////////////////////////////
                  PROXY - FINALIZE UPGRADE
  //////////////////////////////////////////////////////////////*/

  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  /*///////////////////////////////////////////////////////////////
                  INTERNAL HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _rewardPoolBalance() internal view returns (uint256 bal) {
      (bal,) = IElysianFields(rewardPool()).userInfo(poolId(), address(this));
  }

  function _exitRewardPool() internal {
    uint256 bal = _rewardPoolBalance();
    if (bal != 0) {
      IElysianFields(rewardPool()).withdraw(poolId(), bal);
     }
  }

  function _emergencyExitRewardPool() internal {
    uint256 bal = _rewardPoolBalance();
    if (bal != 0) {
      IElysianFields(rewardPool()).emergencyWithdraw(poolId());
    }
  }

  function _enterRewardPool() internal {
    address underlying_ = underlying();
    address rewardPool_ = rewardPool();
    uint256 entireBalance = IERC20(underlying_).balanceOf(address(this));

    IERC20(underlying_).safeApprove(rewardPool_, 0);
    IERC20(underlying_).safeApprove(rewardPool_, entireBalance);

    IElysianFields(rewardPool_).deposit(poolId(), entireBalance);
  }

  // We Hodl all the rewards
  function _hodlAndNotify() internal {
    address rewardToken_ = rewardToken();
    uint256 rewardBalance = IERC20(rewardToken_).balanceOf(address(this));
    if (rewardBalance == 0) {
      return;
    }
    uint256 feeAmount = rewardBalance.mul(profitSharingNumerator()).div(profitSharingDenominator());
    IERC20(rewardToken_).safeTransfer(msig, feeAmount);
    uint256 remainingRewardBalance = IERC20(rewardToken_).balanceOf(address(this));

    if (remainingRewardBalance == 0) {
      return;
    }

    _rewardToLp();

    address holdVault = hodlVault();
    address rewardLp_ = rewardLp();
    uint256 rewardLpBalance = IERC20(rewardLp_).balanceOf(address(this));

    IERC20(rewardLp_).safeApprove(holdVault, 0);
    IERC20(rewardLp_).safeApprove(holdVault, rewardLpBalance);

    IVault(holdVault).deposit(rewardLpBalance);

    uint256 fRewardBalance = IERC20(holdVault).balanceOf(address(this));
    IERC20(holdVault).safeTransfer(potPool(), fRewardBalance);

    PotPool(potPool()).notifyTargetRewardAmount(holdVault, fRewardBalance);
  }

  function _rewardToLp() internal {
    address rewardToken_ = rewardToken();
    uint256 rewardBalance = IERC20(rewardToken_).balanceOf(address(this));

    IERC20(rewardToken_).safeApprove(kyberZapper, 0);
    IERC20(rewardToken_).safeApprove(kyberZapper, rewardBalance);

    IKyberZap(kyberZapper).zapIn({tokenIn: rewardToken_, tokenOut: rewardLpToken1(), userIn: rewardBalance, pool: rewardLp(), to: address(this), minLpQty: 1, deadline: block.timestamp});
  }

    /*
  *   Stakes everything the strategy holds into the reward pool
  */
  function investAllUnderlying() internal onlyNotPausedInvesting {
    // this check is needed, because most of the SNX reward pools will revert if
    // you try to stake(0).
    if(IERC20(underlying()).balanceOf(address(this)) > 0) {
      _enterRewardPool();
    }
  }

  /*///////////////////////////////////////////////////////////////
                  PUBLIC EMERGENCY FUNCTIONS
  //////////////////////////////////////////////////////////////*/

    /*
  *   In case there are some issues discovered about the pool or underlying asset
  *   Governance can exit the pool properly
  *   The function is only used for emergency to exit the pool
  */
  function emergencyExit() public onlyGovernance {
    _emergencyExitRewardPool();
    _setPausedInvesting(true);
  }

  /*
  *   Resumes the ability to invest into the underlying reward pools
  */
  function continueInvesting() public onlyGovernance {
    _setPausedInvesting(false);
  }

  /*///////////////////////////////////////////////////////////////
                  ISTRATEGY FUNCTION IMPLEMENTATIONS
  //////////////////////////////////////////////////////////////*/

  /*
  *   Withdraws all the asset to the vault
  */
  function withdrawAllToVault() public restricted {
    _exitRewardPool();
    _hodlAndNotify();
    address underlying_ = underlying();
    IERC20(underlying_).safeTransfer(vault(), IERC20(underlying_).balanceOf(address(this)));
  }

  /*
  *   Withdraws all the asset to the vault
  */
  function withdrawToVault(uint256 _amount) public restricted {
    // Typically there wouldn't be any amount here
    // however, it is possible because of the emergencyExit
    address underlying_ = underlying();
    uint256 entireBalance = IERC20(underlying_).balanceOf(address(this));

    if(_amount > entireBalance){
      // While we have the check above, we still using SafeMath below
      // for the peace of mind (in case something gets changed in between)
      uint256 needToWithdraw = _amount.sub(entireBalance);
      uint256 toWithdraw = Math.min(_rewardPoolBalance(), needToWithdraw);
      IElysianFields(rewardPool()).withdraw(poolId(), toWithdraw);
    }

    IERC20(underlying_).safeTransfer(vault(), _amount);
  }

  /*
  *   Note that we currently do not have a mechanism here to include the
  *   amount of reward that is accrued.
  */
  function investedUnderlyingBalance() external view returns (uint256) {
    if (rewardPool() == address(0)) {
      return IERC20(underlying()).balanceOf(address(this));
    }
    // Adding the amount locked in the reward pool and the amount that is somehow in this contract
    // both are in the units of "underlying"
    // The second part is needed because there is the emergency exit mechanism
    // which would break the assumption that all the funds are always inside of the reward pool
    return _rewardPoolBalance().add(IERC20(underlying()).balanceOf(address(this)));
  }

  /*
  *   Governance or Controller can claim coins that are somehow transferred into the contract
  *   Note that they cannot come in take away coins that are used and defined in the strategy itself
  */
  function salvage(address _recipient, address _token, uint256 _amount) external onlyControllerOrGovernance {
     // To make sure that governance cannot come in and take away the coins
    require(!unsalvagableTokens(_token), "token is defined as not salvagable");
    IERC20(_token).safeTransfer(_recipient, _amount);
  }

  function unsalvagableTokens(address _token) public view returns (bool) {
    return (_token == rewardToken() || _token == underlying());
  }

  /*
  *   Get the reward, sell it in exchange for underlying, invest what you got.
  *   It's not much, but it's honest work.
  *
  *   Note that although `onlyNotPausedInvesting` is not added here,
  *   calling `investAllUnderlying()` affectively blocks the usage of `doHardWork`
  *   when the investing is being paused by governance.
  */
  function doHardWork() external onlyNotPausedInvesting restricted {
    IElysianFields(rewardPool()).withdraw(poolId(), 0);
    _hodlAndNotify();
    investAllUnderlying();
  }

 function depositArbCheck() public pure returns(bool) {
    return true;
  }

}