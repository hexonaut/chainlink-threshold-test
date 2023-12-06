// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";

interface IEACAggregatorProxy {
    function latestAnswer() external view returns (int256);
}

interface IAccessControlledOffchainAggregator {
    function transmit(bytes calldata _report, bytes32[] calldata _rs, bytes32[] calldata _ss, bytes32 _rawVs) external;
    function transmitters() external view returns (address[] memory);
    function latestConfigDetails() external view returns (uint32 configCount, uint32 blockNumber, bytes16 configDigest);
}

enum Role {
    Unset,
    Signer,
    Transmitter
}

struct Oracle {
    uint8 index;
    Role role;
}

contract ThresholdTest is Test {

    // ETH / USD on Optimism
    IEACAggregatorProxy oracle = IEACAggregatorProxy(0x13e3Ee699D1909E989722E753853AE30b17e08c5);
    IAccessControlledOffchainAggregator aggregator = IAccessControlledOffchainAggregator(0x02f5E9e9dcc66ba6392f6904D5Fcf8625d9B19C9);

    int192 constant FAKE_PRICE = 100_000e8;  // 100k USD / ETH

    function setUp() public {
        vm.createSelectFork(getChain("optimism").rpcUrl, 113144909);  // Dec 6, 2023
    }

    function test_threshold() public {
        assertEq(oracle.latestAnswer(), 2274.54e8);  // 2274.54 USD
        console2.log("original oracle price = %d", oracle.latestAnswer() / 1e8);

        // Run `cast storage 0xE62B71cf983019BFf55bC83B48601ce8419650CC` against mainnet to get the storage layout
        uint256 threshold = (_loadSlotUint(43) >> 168) & 0xFF;
        assertEq(threshold, 3);  // f = 3

        // Generate and replace the signers with known private keys so we can pretend we
        // are a group of 4 authenticated signers
        address genereratedSigner1 = vm.addr(1);
        address genereratedSigner2 = vm.addr(2);
        address genereratedSigner3 = vm.addr(3);
        address genereratedSigner4 = vm.addr(4);
        assertEq(genereratedSigner1, 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf);
        assertEq(genereratedSigner2, 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF);
        assertEq(genereratedSigner3, 0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69);
        assertEq(genereratedSigner4, 0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718);
        _storeSlot(40, genereratedSigner1, _encodeOracle(Oracle(0, Role.Signer)));
        _storeSlot(40, genereratedSigner2, _encodeOracle(Oracle(1, Role.Signer)));
        _storeSlot(40, genereratedSigner3, _encodeOracle(Oracle(2, Role.Signer)));
        _storeSlot(40, genereratedSigner4, _encodeOracle(Oracle(3, Role.Signer)));

        // Sign an arbitrary message with these 4 signers

        // Digest+epoch+round encoding
        (,, bytes16 configDigest) = aggregator.latestConfigDetails();
        bytes32 rawReportContext = bytes32((uint256(bytes32(configDigest)) >> 88) | uint256(0xFFFFFFFFFF));  // epoch & round only needs to be higher than last so we can use 0xFFF...FFF

        // Build observers (this can be made up by signers)
        uint256 obsNeeded = threshold*2+1;  // 2 * f + 1
        bytes32 rawObservers;
        int192[] memory observations = new int192[](obsNeeded);
        uint256 numObservations = obsNeeded;
        for (uint256 i = 0; i < numObservations; i++) {
            observations[i] = FAKE_PRICE;
            rawObservers = bytes32(uint256(rawObservers) | (i << (256 - (i + 1)*8)));
        }

        // Setup message and hash it for signing
        bytes memory message = abi.encode(rawReportContext, rawObservers, observations);
        bytes32 messageHash = keccak256(message);

        // Signing process for 4 signers
        bytes32[] memory rs = new bytes32[](4);
        bytes32[] memory ss = new bytes32[](4);
        bytes32 vs;
        uint8 v1;
        uint8 v2;
        uint8 v3;
        uint8 v4;
        (v1, rs[0], ss[0]) = vm.sign(1, messageHash);
        (v2, rs[1], ss[1]) = vm.sign(2, messageHash);
        (v3, rs[2], ss[2]) = vm.sign(3, messageHash);
        (v4, rs[3], ss[3]) = vm.sign(4, messageHash);
        vs = bytes32((uint256(v1 - 27) << 248) | (uint256(v2 - 27) << 240) | (uint256(v3 - 27) << 232) | (uint256(v4 - 27) << 224));

        // Submit fake price update with 4 oracles + 1 transmitter
        address transmitter1 = aggregator.transmitters()[0];
        vm.prank(transmitter1);
        // You have to set the gas limit for some reason
        aggregator.transmit{ gas: 1_000_000 }(
            message,
            rs,
            ss,
            vs
        );

        // Check that the price is now the fake price
        assertEq(oracle.latestAnswer(), 100_000e8);  // 100k USD
        console2.log("fake oracle price = %d", oracle.latestAnswer() / 1e8);
    }

    function _loadSlotUint(uint256 slot) internal view returns(uint256) {
        return uint256(vm.load(
            address(aggregator),
            bytes32(uint256(slot))
        ));
    }

    function _storeSlot(uint256 slot, address addr, bytes32 value) internal {
        vm.store(
            address(aggregator),
            // Mapping storage
            keccak256(abi.encode(addr, uint256(slot))),
            value
        );
    }

    function _encodeOracle(Oracle memory _oracle) internal pure returns(bytes32) {
        return bytes32(uint256(_oracle.index) | (uint256(uint8(_oracle.role)) << 8));
    }
    
}
