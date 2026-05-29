// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {EcosystemPaymentContract} from "../src/EcosystemPaymentContract-2026.sol";

contract EcosystemPaymentContractTest is Test {
    AIEFToken public token;
    EcosystemPaymentContract public ecosystemPayment;

    address public deployer = address(0xDE);
    address public founderPool = address(0x1111);
    address public lpAccumulator = address(0x2222);
    address public rewardsPool = address(0x3333);
    address public treasurySafe = address(0x4444);
    address public opsSafe = address(0x5555);

    address public payer = address(0x6666);
    address public partnerKey = address(0x7777);
    address public payoutWallet = address(0x8888);

    function setUp() public {
        // Etch code at addresses to bypass code.length > 0 checks in constructors
        vm.etch(founderPool, new bytes(1));
        vm.etch(lpAccumulator, new bytes(1));
        vm.etch(rewardsPool, new bytes(1));
        vm.etch(treasurySafe, new bytes(1));
        vm.etch(opsSafe, new bytes(1));

        vm.startPrank(deployer);
        token = new AIEFToken(founderPool, lpAccumulator);
        vm.stopPrank();

        // EcosystemPaymentContract constructor requires token, rewardsPool, treasurySafe, opsSafe to be contracts
        vm.etch(address(token), address(token).code);

        vm.startPrank(deployer);
        ecosystemPayment = new EcosystemPaymentContract(
            address(token),
            rewardsPool,
            treasurySafe,
            opsSafe
        );

        // Configure exemptions in AIEFToken
        token.setExempt(address(ecosystemPayment), true, false);
        vm.stopPrank();
    }

    function test_Initialization() public {
        assertEq(address(ecosystemPayment.token()), address(token));
        assertEq(ecosystemPayment.rewardsPool(), rewardsPool);
        assertEq(ecosystemPayment.treasurySafe(), treasurySafe);
        assertEq(ecosystemPayment.opsSafe(), opsSafe);
        assertEq(ecosystemPayment.partnerCount(), 0);
        assertEq(ecosystemPayment.totalVolume(), 0);
        assertEq(ecosystemPayment.totalDeadRouted(), 0);
    }

    function test_RegisterPartnerSuccess() public {
        vm.startPrank(opsSafe);
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");
        vm.stopPrank();

        assertEq(ecosystemPayment.partnerCount(), 1);
        assertTrue(ecosystemPayment.isActivePartner(partnerKey));

        (address payout, bool active, string memory name, uint256 volume, uint64 registeredAt) = ecosystemPayment.getPartner(partnerKey);
        assertEq(payout, payoutWallet);
        assertTrue(active);
        assertEq(name, "Partner A");
        assertEq(volume, 0);
        assertEq(registeredAt, block.timestamp);
    }

    function test_RegisterPartnerFailures() public {
        // 1. Revert if not Ops Safe
        vm.expectRevert("EPC: only Ops Safe");
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        vm.startPrank(opsSafe);

        // 2. Revert if zero partnerKey
        vm.expectRevert("EPC: zero partner key");
        ecosystemPayment.registerPartner(address(0), payoutWallet, "Partner A");

        // 3. Revert if zero payoutWallet
        vm.expectRevert("EPC: zero payout wallet");
        ecosystemPayment.registerPartner(partnerKey, address(0), "Partner A");

        // 4. Revert if dead payout wallet
        vm.expectRevert("EPC: dead payout wallet");
        ecosystemPayment.registerPartner(partnerKey, 0x000000000000000000000000000000000000dEaD, "Partner A");

        // 5. Revert if empty name
        vm.expectRevert("EPC: empty name");
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "");

        // 6. Revert if name too long
        string memory longName = "This name is definitely going to exceed the maximum sixty-four bytes limit for partner names";
        vm.expectRevert("EPC: name too long");
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, longName);

        // Success register
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        // 7. Revert if duplicate registration
        vm.expectRevert("EPC: already registered");
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        vm.stopPrank();
    }

    function test_SetPartnerActive() public {
        vm.startPrank(opsSafe);
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        // Deactivate partner
        ecosystemPayment.setPartnerActive(partnerKey, false);
        assertFalse(ecosystemPayment.isActivePartner(partnerKey));

        // Re-activate partner
        ecosystemPayment.setPartnerActive(partnerKey, true);
        assertTrue(ecosystemPayment.isActivePartner(partnerKey));

        // Revert on same status
        vm.expectRevert("EPC: same status");
        ecosystemPayment.setPartnerActive(partnerKey, true);

        // Revert if partner not registered
        vm.expectRevert("EPC: partner not registered");
        ecosystemPayment.setPartnerActive(address(0x999), true);

        vm.stopPrank();
    }

    function test_UpdatePartnerWallet() public {
        vm.startPrank(opsSafe);
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        address newPayout = address(0x999);
        ecosystemPayment.updatePartnerWallet(partnerKey, newPayout);

        (address payout, , , , ) = ecosystemPayment.getPartner(partnerKey);
        assertEq(payout, newPayout);

        // Revert if zero address
        vm.expectRevert("EPC: zero wallet");
        ecosystemPayment.updatePartnerWallet(partnerKey, address(0));

        // Revert if dead address
        vm.expectRevert("EPC: dead payout wallet");
        ecosystemPayment.updatePartnerWallet(partnerKey, 0x000000000000000000000000000000000000dEaD);

        // Revert if same wallet
        vm.expectRevert("EPC: same wallet");
        ecosystemPayment.updatePartnerWallet(partnerKey, newPayout);

        // Revert if partner not registered
        vm.expectRevert("EPC: partner not registered");
        ecosystemPayment.updatePartnerWallet(address(0x999), newPayout);

        vm.stopPrank();
    }

    function test_ProcessPaymentSuccess() public {
        // Register partner
        vm.prank(opsSafe);
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        // Fund payer with AIEF tokens
        uint256 paymentAmount = 1000e18;
        vm.prank(deployer);
        token.transfer(payer, paymentAmount);

        // Approve EPC to spend payer's AIEF
        vm.prank(payer);
        token.approve(address(ecosystemPayment), paymentAmount);

        // Pre-payment balances
        uint256 payerBefore = token.balanceOf(payer);
        uint256 deadBefore = token.balanceOf(0x000000000000000000000000000000000000dEaD);
        uint256 poolBefore = token.balanceOf(rewardsPool);
        uint256 treasuryBefore = token.balanceOf(treasurySafe);
        uint256 partnerBefore = token.balanceOf(payoutWallet);

        // Process payment
        vm.prank(payer);
        ecosystemPayment.processPayment(payer, partnerKey, paymentAmount, bytes32(0), "Invoice #1");

        // Fee calculations:
        // DEAD share: 3% of 1000 = 30 tokens
        // Rewards pool share: 1% of 1000 = 10 tokens
        // Treasury share: 1% of 1000 = 10 tokens
        // Partner share: remainder = 1000 - 30 - 10 - 10 = 950 tokens (95% exactly)
        assertEq(token.balanceOf(payer), payerBefore - paymentAmount);
        assertEq(token.balanceOf(0x000000000000000000000000000000000000dEaD), deadBefore + 30e18);
        assertEq(token.balanceOf(rewardsPool), poolBefore + 10e18);
        assertEq(token.balanceOf(treasurySafe), treasuryBefore + 10e18);
        assertEq(token.balanceOf(payoutWallet), partnerBefore + 950e18);

        // Verify EPC balance is zero
        assertEq(token.balanceOf(address(ecosystemPayment)), 0);

        // Verify volume tracking
        assertEq(ecosystemPayment.totalVolume(), paymentAmount);
        assertEq(ecosystemPayment.totalDeadRouted(), 30e18);
        (, , , uint256 vol, ) = ecosystemPayment.getPartner(partnerKey);
        assertEq(vol, paymentAmount);
    }

    function test_ProcessPaymentFailures() public {
        vm.prank(opsSafe);
        ecosystemPayment.registerPartner(partnerKey, payoutWallet, "Partner A");

        uint256 paymentAmount = 1000e18;
        vm.prank(deployer);
        token.transfer(payer, paymentAmount);

        // 1. Revert if no approval/wrong allowance
        vm.prank(payer);
        vm.expectRevert("EPC: exact allowance required");
        ecosystemPayment.processPayment(payer, partnerKey, paymentAmount, bytes32(0), "Invoice #1");

        // Approve correct amount
        vm.prank(payer);
        token.approve(address(ecosystemPayment), paymentAmount);

        // 2. Revert if caller is not payer
        vm.expectRevert("EPC: caller must be payer");
        ecosystemPayment.processPayment(payer, partnerKey, paymentAmount, bytes32(0), "Invoice #1");

        // 3. Revert on zero payment amount
        vm.prank(payer);
        vm.expectRevert("EPC: zero amount");
        ecosystemPayment.processPayment(payer, partnerKey, 0, bytes32(0), "Invoice #1");

        // 4. Revert if metadata is too long
        string memory longMetadata = "This is a very long metadata description designed specifically to exceed the maximum allowed length of two hundred and fifty-six bytes on the ecosystem payment contract in order to trigger the require validation check during testing runs on foundry, so we add some extra characters to make it exceed two hundred and fifty-six bytes!";
        vm.prank(payer);
        vm.expectRevert("EPC: metadata too long");
        ecosystemPayment.processPayment(payer, partnerKey, paymentAmount, bytes32(0), longMetadata);

        // Deactivate partner
        vm.prank(opsSafe);
        ecosystemPayment.setPartnerActive(partnerKey, false);

        // 5. Revert if partner is not active
        vm.prank(payer);
        vm.expectRevert("EPC: partner not active");
        ecosystemPayment.processPayment(payer, partnerKey, paymentAmount, bytes32(0), "Invoice #1");
    }
}
