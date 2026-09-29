// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Prueba 11 (formal) — pruebas SIMBÓLICAS con halmos de la matemática
/// pura de AutoRangeVaultV1 que hoy sólo tiene fuzz aleatorio de pocas
/// corridas. Las funciones internas relevantes se replican acá 1:1 para que
/// halmos pueda razonar sobre todo el espacio de entrada, no una muestra.
///
///   halmos --contract AutoRangeSymbolicTest --function check_
///
/// Resultado (halmos 0.1.13 + z3): `check_creationFeeFor_tier2NeverUnderflows`
/// PASA (prueba formal de que el bloque `unchecked` de `_creationFeeFor` es
/// seguro — no tiene división). Los otros 4 dan [TIMEOUT] porque todos
/// dividen por `10_000` y z3 no decide división de bitvectores por una
/// constante no-potencia-de-2 en tiempo razonable (limitación conocida de
/// SMT, ajena al contrato). Esas 4 propiedades quedan cubiertas por el fuzz
/// (Prueba 9) + la prueba manual de monotonía de `f(x) = x - floor(x·bps/1e4)`
/// en `AUDIT_OFFICIAL_V1.md`, categoría 2.
contract AutoRangeSymbolicTest is Test {
    // ---------------------------------------------------------------------
    // withdraw(): investableShare - uncountedShare nunca subdesborda
    //   principalUsd = _toStableUsd(...) + (investableShare - uncountedShare)
    //   con investableShare = investableUsdt * bps / 10_000
    //        uncountedShare  = uncountedInvestable * bps / 10_000
    //   y el invariante del contrato uncountedInvestable <= investableUsdt.
    // Se prueba que f(x) = floor(x * bps / 10_000) es monótona no decreciente,
    // así x <= y  ==>  f(x) <= f(y).
    // ---------------------------------------------------------------------

    function check_withdrawShareSubtraction_neverUnderflows(uint256 investable, uint256 uncounted, uint256 bps) public pure {
        // bounds del contrato
        vm.assume(bps <= 10_000);
        // el invariante que el contrato mantiene con clamps en todos lados
        vm.assume(uncounted <= investable);
        // acotar magnitudes a algo realista (unidades de 6 decimales) para
        // que halmos no se vaya a 2^256 — el contrato nunca ve esos valores
        vm.assume(investable < 2 ** 64); // 6-dec USD amounts fit far below this

        uint256 investableShare = (investable * bps) / 10_000;
        uint256 uncountedShare = (uncounted * bps) / 10_000;

        // la resta de withdraw()
        assert(investableShare >= uncountedShare);
        // ergo no hay underflow y el término de principalUsd es >= 0
        uint256 principalTerm = investableShare - uncountedShare;
        assert(principalTerm <= investableShare);
    }

    // ---------------------------------------------------------------------
    // withdraw(): cada balde se decrementa exactamente por su share y el
    // resto nunca es negativo. Además el redondeo SIEMPRE favorece al vault
    // (el share pagado es <= el share exacto real).
    // ---------------------------------------------------------------------

    function check_bucketDecrement_exactAndSafe(uint256 balance, uint256 bps) public pure {
        vm.assume(bps <= 10_000);
        vm.assume(balance < 2 ** 64);

        uint256 share = (balance * bps) / 10_000;
        assert(share <= balance); // el decremento nunca subdesborda
        uint256 remaining = balance - share;
        assert(remaining + share == balance); // contabilidad cerrada
        // multiply-before-divide: el share pagado nunca supera el share exacto
        // (favor al vault). balance*bps/10_000 <= balance  (ya probado), y es
        // el máximo entero <= balance*bps/10_000 real.
        assert(share * 10_000 <= balance * bps);
        assert((share + 1) * 10_000 > balance * bps || share == balance);
    }

    // ---------------------------------------------------------------------
    // _creationFeeFor(): el bloque `unchecked` es seguro.
    //   newTotal   = priorTotal + baseAmount            (nunca decrece)
    //   excessAfter  = newTotal  > threshold ? newTotal  - threshold : 0
    //   excessBefore = priorTotal> threshold ? priorTotal- threshold : 0
    //   tier2 = excessAfter - excessBefore              (debe ser >= 0)
    // ---------------------------------------------------------------------

    function check_creationFeeFor_tier2NeverUnderflows(uint256 priorTotal, uint256 baseAmount, uint256 threshold)
        public
        pure
    {
        // el contrato: cumulativeFeeableUsd sólo crece por montos reales de
        // depósito (escala centavos), lejísimos de 2^256 — mismo supuesto que
        // el comentario `unchecked` del contrato.
        vm.assume(priorTotal < 2 ** 64);
        vm.assume(baseAmount < 2 ** 64);

        unchecked {
            uint256 newTotal = priorTotal + baseAmount;
            assert(newTotal >= priorTotal); // no overflow bajo el supuesto

            uint256 excessAfter = newTotal > threshold ? newTotal - threshold : 0;
            uint256 excessBefore = priorTotal > threshold ? priorTotal - threshold : 0;

            assert(excessAfter >= excessBefore); // <-- lo que hace seguro el `unchecked`
            uint256 tier2 = excessAfter - excessBefore;
            assert(tier2 <= baseAmount); // el excedente de ESTA llamada nunca supera lo aportado
        }
    }

    // ---------------------------------------------------------------------
    // _creationFeeFor(): 2 llamadas secuenciales cobran el mismo tier-2 que
    // 1 sola sobre la suma, modulo redondeo entero de la parte bps (±1 wei
    // por llamada). Sin doble cobro.
    // ---------------------------------------------------------------------

    function _tier2Fee(uint256 priorTotal, uint256 baseAmount, uint256 threshold, uint256 bps)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            uint256 newTotal = priorTotal + baseAmount;
            uint256 excessAfter = newTotal > threshold ? newTotal - threshold : 0;
            uint256 excessBefore = priorTotal > threshold ? priorTotal - threshold : 0;
            uint256 tier2 = excessAfter - excessBefore;
            return (tier2 * bps) / 10_000;
        }
    }

    function check_creationFeeFor_twoLegsApproxOneCall(uint256 a, uint256 b, uint256 threshold, uint256 bps) public pure {
        vm.assume(bps <= 10_000);
        vm.assume(a < 2 ** 48);
        vm.assume(b < 2 ** 48);

        uint256 split = _tier2Fee(0, a, threshold, bps) + _tier2Fee(a, b, threshold, bps);
        uint256 combined = _tier2Fee(0, a + b, threshold, bps);

        // Exacto salvo el truncamiento de la división por llamada.
        assert(split <= combined + 1);
        assert(combined <= split + 1);
    }

    // ---------------------------------------------------------------------
    // _splitPerformanceFee(): net = fee - fee*bps/10_000, con bps<=10_000.
    // net siempre <= fee y platform+net == fee.
    // ---------------------------------------------------------------------

    function check_splitPerformanceFee_conserves(uint256 fee, uint256 bps) public pure {
        vm.assume(bps <= 10_000);
        vm.assume(fee < 2 ** 64);
        uint256 platform = (fee * bps) / 10_000;
        assert(platform <= fee);
        uint256 net = fee - platform;
        assert(net + platform == fee);
    }
}
