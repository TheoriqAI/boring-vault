// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { AaveV4DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV4DecoderAndSanitizer.sol";

contract AaveV4Harness is AaveV4DecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

contract AaveV4DecoderTest is Test {

    AaveV4Harness internal d;

    address internal constant BV = address(0xBEEF);

    function setUp() external {
        d = new AaveV4Harness(BV);
    }

    // --- unit: exact sanitized output -----------------------------------

    function testSupplyPinsOnBehalfOf() external view {
        assertEq(d.supply(7, 100, address(0xA1)), abi.encodePacked(address(0xA1)));
    }

    function testWithdrawPinsOnBehalfOf() external view {
        assertEq(d.withdraw(7, 100, address(0xA2)), abi.encodePacked(address(0xA2)));
    }

    function testBorrowPinsOnBehalfOf() external view {
        assertEq(d.borrow(7, 100, address(0xA3)), abi.encodePacked(address(0xA3)));
    }

    function testRepayPinsOnBehalfOf() external view {
        assertEq(d.repay(7, 100, address(0xA4)), abi.encodePacked(address(0xA4)));
    }

    function testSetUsingAsCollateralPinsOnBehalfOf() external view {
        assertEq(d.setUsingAsCollateral(7, true, address(0xA5)), abi.encodePacked(address(0xA5)));
    }

    function testLiquidationCallPinsUser() external view {
        assertEq(d.liquidationCall(1, 2, address(0xA6), 100, false), abi.encodePacked(address(0xA6)));
    }

    function testSetUserPositionManagerPinsManager() external view {
        assertEq(d.setUserPositionManager(address(0xA7), true), abi.encodePacked(address(0xA7)));
    }

    function testPermitReservePinsOnBehalfOf() external view {
        assertEq(
            d.permitReserve(7, address(0xA8), 100, 200, 27, bytes32(uint256(1)), bytes32(uint256(2))),
            abi.encodePacked(address(0xA8))
        );
    }

    // --- selector self-consistency (verbatim ISpoke.sol signatures) ------

    function testSelectorsMatchISpoke() external view {
        assertEq(d.supply.selector, bytes4(keccak256("supply(uint256,uint256,address)")), "supply");
        assertEq(d.withdraw.selector, bytes4(keccak256("withdraw(uint256,uint256,address)")), "withdraw");
        assertEq(d.borrow.selector, bytes4(keccak256("borrow(uint256,uint256,address)")), "borrow");
        assertEq(d.repay.selector, bytes4(keccak256("repay(uint256,uint256,address)")), "repay");
        assertEq(
            d.setUsingAsCollateral.selector,
            bytes4(keccak256("setUsingAsCollateral(uint256,bool,address)")),
            "setUsingAsCollateral"
        );
        assertEq(
            d.liquidationCall.selector,
            bytes4(keccak256("liquidationCall(uint256,uint256,address,uint256,bool)")),
            "liquidationCall"
        );
        assertEq(
            d.setUserPositionManager.selector,
            bytes4(keccak256("setUserPositionManager(address,bool)")),
            "setUserPositionManager"
        );
        assertEq(
            d.permitReserve.selector,
            bytes4(keccak256("permitReserve(uint256,address,uint256,uint256,uint8,bytes32,bytes32)")),
            "permitReserve"
        );
    }

    // --- LIVE: confirm the canonical mainnet hubs & spokes are deployed ---
    // Addresses are verbatim from bgd-labs/aave-address-book src/AaveV4Ethereum.sol (chainid 1).
    // Gated: skips when MAINNET_RPC_URL is unset so CI without an archive node stays green.

    function testFork_HubsAndSpokesAreLiveOnMainnet() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("MAINNET_RPC_URL unset - skipping Aave v4 live check");
            vm.skip(true);
            return;
        }
        // A dead/unreachable RPC must SKIP (not fail) — only assert when we truly have a mainnet fork.
        try vm.createSelectFork(rpc) returns (uint256) {
            _assertHubsAndSpokesLive();
        } catch {
            emit log("mainnet RPC unreachable - skipping Aave v4 live check");
            vm.skip(true);
        }
    }

    function _assertHubsAndSpokesLive() internal view {
        address[4] memory hubs = [
            0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9, // CORE_HUB
            0x06002e9c4412CB7814a791eA3666D905871E536A, // PLUS_HUB
            0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931, // PRIME_HUB
            0x62d63197660c080236193CA60b70E49A08E90368 // PAXOS_HUB
        ];
        for (uint256 i; i < hubs.length; ++i) {
            assertGt(hubs[i].code.length, 0, "hub has no code on mainnet");
        }

        address[12] memory spokes = [
            0xB9B0b8616f6Bf6841972a52058132BE08d723155, // TREASURY_SPOKE
            0x973a023A77420ba610f06b3858aD991Df6d85A08, // BLUECHIP_SPOKE
            0x58131E79531caB1d52301228d1f7b842F26B9649, // ETHENA_CORRELATED_SPOKE
            0xba1B3D55D249692b669A164024A838309B7508AF, // ETHENA_ECOSYSTEM_SPOKE
            0xD8B93635b8C6d0fF98CbE90b5988E3F2d1Cd9da1, // FOREX_SPOKE
            0x65407b940966954b23dfA3caA5C0702bB42984DC, // GOLD_SPOKE
            0x7EC68b5695e803e98a21a9A05d744F28b0a7753D, // LOMBARD_BTC_SPOKE
            0x94e7A5dCbE816e498b89aB752661904E2F56c485, // MAIN_SPOKE
            0x956d8e0A89cfa3744428C4641b5a53B56167a7f9, // USDG_PENDLE_SPOKE
            0xbF10BDfE177dE0336aFD7fcCF80A904E15386219, // ETHERFI_ESPOKE
            0x3131FE68C4722e726fe6B2819ED68e514395B9a4, // KELP_ESPOKE
            0xe1900480ac69f0B296841Cd01cC37546d92F35Cd // LIDO_ESPOKE
        ];
        for (uint256 i; i < spokes.length; ++i) {
            assertGt(spokes[i].code.length, 0, "spoke has no code on mainnet");
        }
    }

}
