// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================== YieldSpaceAMO ===========================
// ====================================================================
// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Jack Corddry: https://github.com/corddry
// Sam Kazemian: https://github.com/samkazemian
// Dennis: https://github.com/denett

import {Owned} from "./utils/Owned.sol";
import {IFrax} from "./interfaces/IFrax.sol";
import {ILadle} from "vault-interfaces/ILadle.sol";
import {IPool} from "yieldspace-interfaces/IPool.sol";
import {IFYToken} from "vault-interfaces/IFYToken.sol";
import {ICauldron} from "vault-interfaces/ICauldron.sol";
import {IFraxAMOMinter} from "./interfaces/IFraxAMOMinter.sol";
import {CastU256U128} from "yield-utils-v2/contracts/cast/CastU256U128.sol";
import {CastU128I128} from "yield-utils-v2/contracts/cast/CastU128I128.sol";
import {YieldMath} from "yieldspace-v2/contracts/YieldMath.sol";
import {Math64x64} from "yieldspace-v2/contracts/Math64x64.sol";
import {Pool, Exp64x64} from "yieldspace-v2/contracts/Pool.sol";

import "forge-std/console.sol"; // todo: remove me

library r {
    using Math64x64 for int128;

    function rPow(
        uint128 x,
        uint128 y,
        uint128 z
    ) public pure returns (int128) {
        return Math64x64.exp(Math64x64.ln(int128(x).mul(int128(y).div(int128(z)))));
    }
}

contract YieldSpaceAMO is Owned {
    using CastU256U128 for uint256;
    using CastU128I128 for uint128;
    using Math64x64 for int128;
    // using Math64x64 for uint128;
    // using Math64x64 for int256;
    using Math64x64 for uint256;
    using Exp64x64 for uint128;
    using r for uint128;

    /* =========== CONSTANTS =========== */
    bytes6 public constant FRAX_ILK_ID = 0x313800000000;

    /* =========== DATA TYPES =========== */
    struct Series {
        bytes12 vaultId; /// @notice The AMO's debt & collateral record for this series
        IFYToken fyToken;
        IPool pool;
        uint96 maturity;
    }

    /* =========== STATE VARIABLES =========== */

    // Frax
    IFrax private immutable FRAX;
    IFraxAMOMinter private amoMinter;
    address public timelockAddress;
    address public custodianAddress;

    // Yield Protocol
    ILadle public immutable ladle;
    ICauldron public immutable cauldron;
    address public immutable fraxJoin;
    mapping(bytes6 => Series) public series;
    bytes6[] internal _seriesIterator;

    // AMO
    uint256 public currentAMOmintedFRAX; /// @notice The amount of FRAX tokens minted by the AMO
    uint256 public currentAMOmintedFyFRAX;

    /* ============= CONSTRUCTOR ============= */
    constructor(
        address _ownerAddress,
        address _amoMinterAddress,
        address _yieldLadle,
        address _yieldFraxJoin,
        address _frax
    ) Owned(_ownerAddress) {
        FRAX = IFrax(_frax);
        amoMinter = IFraxAMOMinter(_amoMinterAddress);
        timelockAddress = amoMinter.timelock_address();

        ladle = ILadle(_yieldLadle);
        cauldron = ICauldron(ladle.cauldron());
        fraxJoin = _yieldFraxJoin;

        currentAMOmintedFRAX = 0;
        currentAMOmintedFyFRAX = 0;
    }

    /* ============== MODIFIERS ============== */
    modifier onlyByOwnGov() {
        require(msg.sender == timelockAddress || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByMinter() {
        require(msg.sender == address(amoMinter), "Not minter");
        _;
    }

    /* ================ VIEWS ================ */
    // /// @notice returns current rate on Frax debt
    // function getRate() public view returns (uint256) { //TODO Name better & figure out functionality
    //     return (circulatingAMOMintedFyFrax() - currentRaisedFrax()) / (currentRaisedFrax() * /*timeremaining*/; //TODO pos/neg
    // }

    function showAllocations(bytes6 seriesId) public view returns (uint256[6] memory) {
        Series storage _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");
        uint256 supply = _series.pool.totalSupply();
        uint256 fraxInContract = FRAX.balanceOf(address(this));
        uint256 fraxAsCollateral = cauldron.balances(_series.vaultId).ink;
        uint256 fraxInLP = supply == 0
            ? 0
            : (FRAX.balanceOf(address(_series.pool)) * _series.pool.balanceOf(address(this))) /
                _series.pool.totalSupply();
        uint256 fyFraxInContract = _series.fyToken.balanceOf(address(this));
        uint256 fyFraxInLP = supply == 0
            ? 0
            : (_series.fyToken.balanceOf(address(_series.pool)) * _series.pool.balanceOf(address(this))) /
                _series.pool.totalSupply();
        uint256 LPOwned = _series.pool.balanceOf(address(this));
        return [
            fraxInContract, // [0] Unallocated Frax
            fraxAsCollateral, // [1] Frax being used as collateral to borrow fyFrax
            fraxInLP, // [2] The Frax our LP tokens can lay claim to
            fyFraxInContract, // [3] fyFrax sitting in AMO, should be 0
            fyFraxInLP, // [4] fyFrax our LP can claim
            LPOwned // [5] number of LP tokens
        ];
    }

    /// @notice Return the Frax value of a fyFrax amount, considering a debt repayment if possible.
    function fraxValue(bytes6 seriesId, uint256 fyFraxAmount) public view returns (uint256 fraxAmount) {
        Series storage _series = series[seriesId];

        // After maturity, it's 1:1
        if (block.timestamp > _series.maturity) {
            fraxAmount = fyFraxAmount;
        } else {
            uint256 debt = cauldron.balances(_series.vaultId).art;
            if (debt > fyFraxAmount) {
                // For as long as there is debt, it's 1:1
                fraxAmount = fyFraxAmount;
            } else {
                // The fyFrax over the debt, we would need to sell it.
                try _series.pool.sellFYTokenPreview((fyFraxAmount - debt).u128()) returns (uint128 fraxBought) {
                    fraxAmount = debt + fraxBought;
                } catch (bytes memory) {
                    // If for some reason the fyFrax can't be sold, we value it at zero
                    fraxAmount = debt;
                }
            }
        }
    }

    /// @notice Return the value of all AMO assets in Frax terms.
    function currentFrax() public view returns (uint256 fraxAmount) {
        // Add value from Frax in the AMO
        fraxAmount = FRAX.balanceOf(address(this));

        // Add up the amount of FRAX in LP positions
        // Add up the value in Frax from all fyFRAX LP positions
        uint256 activeSeries = _seriesIterator.length;
        for (uint256 s; s < activeSeries; ++s) {
            bytes6 seriesId = _seriesIterator[s];
            Series storage _series = series[seriesId];
            uint256 supply = _series.pool.totalSupply();
            uint256 poolShare = supply == 0 ? 0 : (1e18 * _series.pool.balanceOf(address(this))) / supply;

            // Add value from Frax in LP positions
            fraxAmount += (FRAX.balanceOf(address(_series.pool)) * poolShare) / 1e18;

            // Add value from fyFrax in the AMO and LP positions
            uint256 fyFraxAmount = _series.fyToken.balanceOf(address(this));
            fyFraxAmount += (_series.fyToken.balanceOf(address(_series.pool)) * poolShare) / 1e18;
            fraxAmount += fraxValue(seriesId, fyFraxAmount);
        }
    }

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    function dollarBalances() public view returns (uint256 valueAsFrax, uint256 valueAsCollateral) {
        valueAsFrax = currentFrax();
        valueAsCollateral = (valueAsFrax * FRAX.global_collateral_ratio()) / 1e6; // This assumes that FRAX.global_collateral_ratio() has 6 decimals
    }

    /// @notice returns entire _seriesIterator array.
    /// @dev Solcurity Standard https://github.com/Rari-Capital/solcurity:
    /// V9 - If it's a public array, is a separate function provided to return the full array
    /// Also useful for testing.
    function seriesIterator() external view returns (bytes6[] memory seriesIterator_) {
        seriesIterator_ = _seriesIterator;
    }

    /// @notice Returns current pool fyFrax:Frax ratio as fp18
    /// @param seriesId Id of series to check pool
    function currentRate(bytes6 seriesId) external view returns (uint256) {
        return _currentRate(seriesId);
    }

    function _currentRate(bytes6 seriesId) internal view returns (uint256) {
        Series storage _series = series[seriesId];
        (uint128 base, uint128 fyToken, ) = _series.pool.getCache();
        return (uint256(fyToken) * 1e18) / base;
    }

    // / @return fraxAmountForIncrease Amount of FRAX which will be used to mint fyFrax and increase pool ratio to newRate.
    // / Neither this number nor the next number account for FRAX currently in the AMO.  TODO: should it?
    // / @return fraxAmountForDecrease Amount of FRAX which will be sold to decrease rates to newRate
    // function fraxForNewRate(uint256 newRate) external view returns(uint256 fraxAmountForIncrease, uint256 fraxAmountForDecrease) {

    /// @notice determines the amount of FRAX that would be used to change rates
    /// ignores FRAX already in the AMO. // TODO: do we want to account for FRAX in the AMO already?
    /// https://www.desmos.com/calculator/cmssbverdd
    /// @param seriesId id of series with pool to adjust rates for
    /// @param newRate new rate as fp18
    /// @return fraxAmount
    // TODO: Move this fns and all helpers including libs and _computeA to a library
    function fraxForNewRate(bytes6 seriesId, uint256 newRate) external view returns (uint256 fraxAmount) {
        //  x1 = current fyFraxReserves (fp18)
        //  x2 = new fyFraxReserves (fp18)
        //  y1 = current Frax reserves (fp18)
        //  g  = fees ratio (64bit)
        //  t = fraction of timeStretch (64bit)
        //  r = newRate (fp18)
        //  a = 1-gt
        //  newFyFraxReserves = ( ( currentFyReserve))
        //
        //      ( numerator         ) / (       denominator      )
        // x2 = ( x1^a + y1^a )^(1/a) / (1 +  ((1 + r)^u)^a)^(1/a)

        //NOTE: Increase rates = g2
        (uint128 termA, uint128 termB, uint128 a, uint128 u) = _getTerms(seriesId);
        console.log(1);
        int128 r64 = newRate.fromUInt().div(uint256(1e18).fromUInt());
        console.log("+ + file: YieldSpaceAMO.sol + line 241 + fraxForNewRate + r64", uint128(r64));
        int128 ru64 = (int128(YieldMath.ONE) + r64).pow(int128(u).toUInt());
        console.log("+ + file: YieldSpaceAMO.sol + line 243 + fraxForNewRate + ru64", uint128(ru64));
        // console.log(
        //     "+ + file: YieldSpaceAMO.sol + line 243 + fraxForNewRate + denomralizedru64",
        //     uint128(_denormalize(ru64, int128(a), int128(YieldMath.ONE)))
        // );
        console.log(2);
        int128 rua64 = int128(uint128(ru64).rPow(a, YieldMath.ONE));
        console.log(3);
        int128 denominator64 = int128(uint128(int128(YieldMath.ONE) + rua64).rPow(YieldMath.ONE, a));
        console.log("+ + file: YieldSpaceAMO.sol + line 246 + fraxForNewRate + denominator64", uint128(denominator64));
        console.log(4);
        uint128 xy = (termA + termB);
        console.log(5);
        uint256 numerator = uint256(uint128(int128(xy.rPow(YieldMath.ONE, a)).div(uint256(1e18).fromUInt()))); // change from wei to whole frax
        console.log("+ + file: YieldSpaceAMO.sol + line 250 + fraxForNewRate + numerator", numerator);
        // console.log(
        //     "+ + file: YieldSpaceAMO.sol + line 250 + fraxForNewRate + _denormalize ONE, a ONE",
        //     uint128(_denormalize(int128(YieldMath.ONE), int128(a), int128(YieldMath.ONE)))
        // );
        console.log(6);
        int128 numerator64 = numerator.fromUInt();
        console.log("+ + file: YieldSpaceAMO.sol + line 247 + fraxForNewRate + numerator64", uint128(numerator64));
        // fraxAmount = ((numerator64.div(denominator64)).toUInt()) * 1e18;
        fraxAmount = uint256((numerator64.div(denominator64)).toUInt()) * 1e18;
        console.log("+ + file: YieldSpaceAMO.sol + line 246 + fraxForNewRate + fraxAmount", fraxAmount);
    }

    // function _denormalize(
    //     int128 raised,
    //     int128 y,
    //     int128 z
    // ) internal pure returns (int128) {
    //     return
    //         raised.div(
    //             int128(
    //                 (YieldMath.TWO).rPow(
    //                     uint128((uint256(128).fromUInt()).mul(int128(YieldMath.ONE) - y.div(z))),
    //                     YieldMath.ONE
    //                 )
    //             )
    //         );
    // }

    function _getTerms(bytes6 seriesId)
        internal
        view
        returns (
            uint128 termA,
            uint128 termB,
            uint128 a,
            uint128 u
        )
    {
        Series storage _series = series[seriesId];
        (uint128 x1, uint128 y1, ) = _series.pool.getCache();
        console.log("+ + file: YieldSpaceAMO.sol + line 250 + _getTerms + y1", y1);
        console.log("+ + file: YieldSpaceAMO.sol + line 250 + _getTerms + x1", x1);
        int128 g = _series.pool.g2(); // TODO: for now assume increase rates, later make this dynamic g1/g2 depending if inc or dec rates
        console.log(
            uint128(_series.pool.ts().mul(uint256(_series.pool.maturity() - uint32(block.timestamp)).fromUInt()))
        );
        a = YieldMath._computeA(_series.pool.maturity() - uint32(block.timestamp), _series.pool.ts(), g);
        console.log("+ + file: YieldSpaceAMO.sol + line 260 + _getTerms + a", a);
        console.log("+ + file: YieldSpaceAMO.sol + line 260 + _getTerms + g", uint128(g));
        console.log(
            "+ + file: YieldSpaceAMO.sol + line 260 + _getTerms + _series.pool.ts()",
            uint128(_series.pool.ts())
        );
        console.log(
            "+ + file: YieldSpaceAMO.sol + line 260 + _getTerms + _series.pool.maturity() - uint32(block.timestamp)",
            uint128(_series.pool.maturity() - uint32(block.timestamp))
        );
        console.log(
            "kt",
            uint128(_series.pool.ts().mul(uint256(_series.pool.maturity() - uint32(block.timestamp)).fromUInt()))
        );
        termA = uint128(x1.rPow(a, YieldMath.ONE));
        console.log("+ + file: YieldSpaceAMO.sol + line 255 + _getTerms + termA", termA);
        termB = uint128(y1.rPow(a, YieldMath.ONE));
        console.log("+ + file: YieldSpaceAMO.sol + line 257 + _getTerms + termB", termB);
        int128 invTs = int128(YieldMath.ONE).div(_series.pool.ts());
        u = uint128((invTs.toUInt() / uint256(365 * 24 * 60 * 60)).fromUInt());
        console.log("+ + file: YieldSpaceAMO.sol + line 279 + _getTerms + u", u);
    }

    function getU(bytes6 seriesId) public view returns (uint256) {
        Series storage _series = series[seriesId];
        int128 invTs = int128(YieldMath.ONE).div(_series.pool.ts());
        return (invTs.toUInt() / (365 * 24 * 60 * 60) + 5e17) / 1e18;
    }

    function getG1(bytes6 seriesId) public view returns (uint256) {
        Series storage _series = series[seriesId];
        return _series.pool.g1().mul(uint256(1e18).fromUInt()).toUInt();
    }

    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice register a new series in the AMO
    /// @param seriesId the series being added
    function addSeries(
        bytes6 seriesId,
        IFYToken fyToken,
        IPool pool
    ) public onlyByOwnGov {
        require(ladle.pools(seriesId) == address(pool), "Mismatched pool");
        require(cauldron.series(seriesId).fyToken == fyToken, "Mismatched fyToken");

        (bytes12 vaultId, ) = ladle.build(seriesId, FRAX_ILK_ID, 0);
        series[seriesId] = Series({
            vaultId: vaultId,
            fyToken: fyToken,
            pool: pool,
            maturity: uint96(fyToken.maturity()) // Will work for a while.
        });

        _seriesIterator.push(seriesId);
    }

    /// @notice remove a new series in the AMO, to keep gas costs in place
    /// @param seriesId the series being removed
    /// @param seriesIndex the index in the _seriesIterator for the series being removed
    function removeSeries(bytes6 seriesId, uint256 seriesIndex) public onlyByOwnGov {
        Series memory _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");
        require(seriesId == _seriesIterator[seriesIndex], "Index mismatch");
        require(_series.fyToken.balanceOf(address(this)) == 0, "Outstanding fyToken balance");
        require(_series.pool.balanceOf(address(this)) == 0, "Outstanding pool balance");

        delete series[seriesId];

        // Remove the seriesId from the iterator, by replacing for the tail and popping.
        uint256 activeSeries = _seriesIterator.length;
        if (seriesIndex < activeSeries - 1) {
            _seriesIterator[seriesIndex] = _seriesIterator[activeSeries - 1];
        }
        _seriesIterator.pop();
    }

    /// @notice mint fyFrax using FRAX as collateral 1:1 Frax to fyFrax
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series being minted
    /// @param fraxAmount amount of Frax being used to mint fyFrax at 1:1
    function mintFyFrax(bytes6 seriesId, uint128 fraxAmount) public onlyByOwnGov returns (uint128 fyFraxMinted) {
        Series memory _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");
        fyFraxMinted = _mintFyFrax(_series, address(this), fraxAmount);
    }

    /// @notice mint fyFrax using FRAX as collateral 1:1 Frax to fyFrax
    /// @dev The Frax to work with needs to be in the AMO already.
    /// If there is any fyFrax in the AMO for the right series, it's used first.
    /// @param _series fyFrax series being minted
    /// @param to destination for the fyFrax
    /// @param fraxAmount amount of Frax being used to mint fyFrax at 1:1
    function _mintFyFrax(
        Series memory _series,
        address to,
        uint128 fraxAmount
    ) internal returns (uint128 fyFraxMinted) {
        uint128 fyFraxAvailable = _series.fyToken.balanceOf(address(this)).u128();

        if (fyFraxAvailable > fraxAmount) {
            // If we don't need to mint, then we don't do it.
            _series.fyToken.transfer(to, fraxAmount);
        } else if (fyFraxAvailable > 0) {
            // We have some fyFrax, but we need to mint more.
            fyFraxMinted = fraxAmount - fyFraxAvailable;
            _series.fyToken.transfer(to, fyFraxAvailable);
        } else {
            // We need to mint the whole lot
            fyFraxMinted = fraxAmount;
        }

        if (fyFraxMinted > 0) {
            int128 fyFraxMinted_ = fyFraxMinted.i128();
            //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
            FRAX.transfer(fraxJoin, fyFraxMinted);
            ladle.pour(_series.vaultId, to, fyFraxMinted_, fyFraxMinted_);
        }
    }

    /// @notice recover Frax from an amount of fyFrax, repaying or redeeming.
    /// Before maturity, if there isn't enough debt to convert all the fyFrax into Frax, the surplus
    /// will be stored in the AMO. Calling this function after maturity will redeem the surplus.
    /// @dev The fyFrax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series being burned
    /// @param fyFraxAmount amount of fyFrax being burned
    /// @return fraxAmount amount of Frax recovered
    /// @return fyFraxStored amount of fyFrax stored in the AMO
    function burnFyFrax(bytes6 seriesId, uint128 fyFraxAmount)
        public
        onlyByOwnGov
        returns (uint256 fraxAmount, uint128 fyFraxStored)
    {
        Series memory _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");

        (fraxAmount, fyFraxStored) = _burnFyFrax(_series, address(this), fyFraxAmount);
    }

    /// @notice recover Frax from an amount of fyFrax, repaying or redeeming.
    /// Before maturity, if there isn't enough debt to convert all the fyFrax into Frax, the surplus
    /// will be stored in the AMO. Calling this function after maturity will redeem the surplus.
    /// @dev The fyFrax to work with needs to be in the AMO already.
    /// @param _series fyFrax series being burned
    /// @param to destination for the frax recovered
    /// @param fyFraxAmount amount of fyFrax being burned
    /// @return fraxAmount amount of Frax recovered
    /// @return fyFraxStored amount of fyFrax stored in the AMO
    function _burnFyFrax(
        Series memory _series,
        address to,
        uint128 fyFraxAmount
    ) internal returns (uint256 fraxAmount, uint128 fyFraxStored) {
        if (_series.maturity < block.timestamp) {
            // At maturity, forget about debt and redeem at 1:1
            _series.fyToken.transfer(address(_series.fyToken), fyFraxAmount);
            fraxAmount = _series.fyToken.redeem(to, fyFraxAmount);
        } else {
            // Before maturity, repay as much debt as possible, and keep any surplus fyFrax
            uint256 debt = cauldron.balances(_series.vaultId).art;
            (fraxAmount, fyFraxStored) = debt > fyFraxAmount ? (fyFraxAmount, 0) : (debt, (fyFraxAmount - debt).u128());
            // When repaying with fyFrax, we don't need to approve anything
            ladle.pour(_series.vaultId, to, -(fraxAmount.u128().i128()), -(fraxAmount.u128().i128()));
        }
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series we are increasing the rates for
    /// @param fraxAmount amount of Frax being converted to fyFrax and sold
    /// @param minFraxReceived minimum amount of Frax to receive in the sale
    /// @return fraxReceived amount of Frax received in the sale
    function increaseRates(
        bytes6 seriesId,
        uint128 fraxAmount,
        uint128 minFraxReceived
    ) public onlyByOwnGov returns (uint256 fraxReceived) {
        Series storage _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");

        // Mint fyFRAX into the pool, and sell it.
        _mintFyFrax(_series, address(_series.pool), fraxAmount);
        fraxReceived = _series.pool.sellFYToken(address(this), minFraxReceived);
        emit RatesIncreased(fraxAmount, fraxReceived);
    }

    /// @notice buy fyFrax from the AMO and burn it to push down rates
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series we are decreasing the rates for
    /// @param fraxAmount amount of Frax being sold for fyFrax
    /// @param minFyFraxReceived minimum amount of fyFrax in the sale
    /// @return fraxReceived amount of Frax received after selling and burning
    /// @return fyFraxStored amount of fyFrax stored in the AMO, if any
    function decreaseRates(
        bytes6 seriesId,
        uint128 fraxAmount,
        uint128 minFyFraxReceived
    ) public onlyByOwnGov returns (uint256 fraxReceived, uint256 fyFraxStored) {
        Series memory _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        FRAX.transfer(address(_series.pool), fraxAmount);

        uint256 fyFraxReceived = _series.pool.sellBase(address(this), minFyFraxReceived);
        (fraxReceived, fyFraxStored) = _burnFyFrax(_series, address(this), fyFraxReceived.u128());

        emit RatesDecreased(fraxAmount, fraxReceived);
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    /// @dev The Frax to work with needs to be in the AMO already for both fraxAmount and fyFraxAmount
    /// @param seriesId fyFrax series we are adding liquidity for
    /// @param fraxAmount Frax being provided as liquidity
    /// @param fyFraxAmount amount of fyFrax being provided as liquidity - this amount of frax also needs to be in AMO already
    /// @param minRatio minimum Frax/fyFrax ratio accepted in the pool
    /// @param maxRatio maximum Frax/fyFrax ratio accepted in the pool
    /// @return fraxUsed amount of Frax used for minting, it could be less than `fraxAmount`
    /// @return poolMinted amount of pool tokens minted
    function addLiquidityToAMM(
        bytes6 seriesId,
        uint128 fraxAmount,
        uint128 fyFraxAmount,
        uint256 minRatio,
        uint256 maxRatio
    ) public onlyByOwnGov returns (uint256 fraxUsed, uint256 poolMinted) {
        Series storage _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");
        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        _mintFyFrax(_series, address(_series.pool), fyFraxAmount);
        FRAX.transfer(address(_series.pool), fraxAmount);
        (fraxUsed, , poolMinted) = _series.pool.mint(address(this), address(this), minRatio, maxRatio); //Second param receives remainder
        emit LiquidityAdded(fraxUsed, poolMinted);
    }

    /// @notice remove liquidity and burn fyTokens
    /// @dev The pool tokens to work with need to be in the AMO already.
    /// @param seriesId fyFrax series we are adding liquidity for
    /// @param poolAmount amount of pool tokens being removed as liquidity
    /// @param minRatio minimum Frax/fyFrax ratio accepted in the pool
    /// @param maxRatio maximum Frax/fyFrax ratio accepted in the pool
    /// @return fraxReceived amount of Frax received after removing liquidity and burning
    /// @return fyFraxStored amount of fyFrax stored in the AMO, if any
    function removeLiquidityFromAMM(
        bytes6 seriesId,
        uint256 poolAmount,
        uint256 minRatio,
        uint256 maxRatio
    ) public onlyByOwnGov returns (uint256 fraxReceived, uint256 fyFraxStored) {
        Series storage _series = series[seriesId];
        require(_series.vaultId != bytes12(0), "Series not found");
        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX coming into this contract and then burned.
        //Instruct the Ladle to repay as much debt as fyFRAX from the burn, and withdraw the same amount of collateral.
        _series.pool.transfer(address(_series.pool), poolAmount);
        (, , uint256 fyFraxAmount) = _series.pool.burn(address(this), address(this), minRatio, maxRatio);
        (fraxReceived, fyFraxStored) = _burnFyFrax(_series, address(this), fyFraxAmount.u128());
        emit LiquidityRemoved(fraxReceived, poolAmount);
    }

    /* === RESTRICTED GOVERNANCE FUNCTIONS === */
    function setAMOMinter(IFraxAMOMinter _amoMinter) external onlyByOwnGov {
        amoMinter = _amoMinter;

        // Get the timelock addresses from the minter
        timelockAddress = _amoMinter.timelock_address();

        // Make sure the new addresses are not address(0)
        require(timelockAddress != address(0), "Invalid timelock");
        emit AMOMinterSet(address(_amoMinter));
    }

    /// @notice generic proxy
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = to.call{value: value}(data);
        return (success, result);
    }

    /* ================ EVENTS =============== */
    //TODO What other events do we want?
    event LiquidityAdded(uint256 fraxUsed, uint256 poolMinted);
    event LiquidityRemoved(uint256 fraxReceived, uint256 poolBurned);
    event RatesIncreased(uint256 fraxUsed, uint256 fraxReceived);
    event RatesDecreased(uint256 fraxUsed, uint256 fraxReceived);
    event AMOMinterSet(address amoMinterAddress);
}
