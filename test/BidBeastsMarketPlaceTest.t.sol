// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BidBeastsNFTMarket} from "../src/BidBeastsNFTMarketPlace.sol";
import {BidBeasts} from "../src/BidBeasts_NFT_ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// A mock contract that cannot receive Ether, to test the payout failure logic.
contract RejectEther {
    // Intentionally has no payable receive or fallback
}

// A contract that can receive ERC721 safely but rejects ETH transfers
contract RejectingSeller is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    // Explicitly reject ETH transfers
    receive() external payable {
        revert("no eth");
    }
    fallback() external payable {
        revert("no eth");
    }
}

// A bidder contract that can send bids but rejects ETH refunds
contract ToggleRefundBidder {
    bool public rejectRefunds = true;

    function bid(address market, uint256 tokenId) external payable {
        (bool ok, ) = market.call{value: msg.value}(abi.encodeWithSignature("placeBid(uint256)", tokenId));
        require(ok, "bid failed");
    }

    function setRejectRefunds(bool reject) external {
        rejectRefunds = reject;
    }

    receive() external payable {
        if (rejectRefunds) revert("no refund");
    }
}

contract BidBeastsNFTMarketTest is Test {
    // --- State Variables ---
    BidBeastsNFTMarket market;
    BidBeasts nft;
    RejectEther rejector;

    // --- Users ---
    address public constant OWNER = address(0x1); // Contract deployer/owner
    address public constant SELLER = address(0x2);
    address public constant BIDDER_1 = address(0x3);
    address public constant BIDDER_2 = address(0x4);

    // --- Constants ---
    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant TOKEN_ID = 0;
    uint256 public constant MIN_PRICE = 1 ether;
    uint256 public constant BUY_NOW_PRICE = 5 ether;

    function setUp() public {
        // Deploy contracts
        vm.prank(OWNER);
        nft = new BidBeasts();
        market = new BidBeastsNFTMarket(address(nft));
        rejector = new RejectEther();

        vm.stopPrank();

        // Fund users
        vm.deal(SELLER, STARTING_BALANCE);
        vm.deal(BIDDER_1, STARTING_BALANCE);
        vm.deal(BIDDER_2, STARTING_BALANCE);
    }

    // --- Helper function to list an NFT ---
    function _listNFT() internal {
        vm.startPrank(SELLER);
        nft.approve(address(market), TOKEN_ID);
        market.listNFT(TOKEN_ID, MIN_PRICE, BUY_NOW_PRICE);
        vm.stopPrank();
    }

    // -- Helper function to mint an NFT ---
    function _mintNFT() internal {
        vm.startPrank(OWNER);
        nft.mint(SELLER);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            LISTING TESTS
    //////////////////////////////////////////////////////////////*/
    function test_listNFT() public {

        _mintNFT();
        _listNFT();

        assertEq(nft.ownerOf(TOKEN_ID), address(market), "NFT should be held by the market");
        BidBeastsNFTMarket.Listing memory listing = market.getListing(TOKEN_ID);
        assertEq(listing.seller, SELLER);
        assertEq(listing.minPrice, MIN_PRICE);
    }

    function test_fail_listNFT_notOwner() public {
        vm.prank(BIDDER_1);
        vm.expectRevert("Not the owner");
        market.listNFT(TOKEN_ID, MIN_PRICE, BUY_NOW_PRICE);
    }
    

    function test_unlistNFT() public {
        _mintNFT();
        _listNFT();

        vm.prank(SELLER);
        market.unlistNFT(TOKEN_ID);
        
        assertEq(nft.ownerOf(TOKEN_ID), SELLER, "NFT should be returned to seller");
        assertFalse(market.getListing(TOKEN_ID).listed, "Listing should be marked as unlisted");
    }

    /*//////////////////////////////////////////////////////////////
                            BIDDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_placeFirstBid() public {
        _mintNFT();
        _listNFT();

        vm.prank(BIDDER_1);
        market.placeBid{value: MIN_PRICE}(TOKEN_ID);

        BidBeastsNFTMarket.Bid memory highestBid = market.getHighestBid(TOKEN_ID);
        assertEq(highestBid.bidder, BIDDER_1);
        assertEq(highestBid.amount, MIN_PRICE);
        assertEq(market.getListing(TOKEN_ID).auctionEnd, block.timestamp + market.S_AUCTION_EXTENSION_DURATION());
    }

    function test_placeSubsequentBid_RefundsPrevious() public {
        _mintNFT();
        _listNFT();

        vm.prank(BIDDER_1);
        market.placeBid{value: MIN_PRICE}(TOKEN_ID);

        uint256 bidder1BalanceBefore = BIDDER_1.balance;
        
        uint256 secondBidAmount = MIN_PRICE * 120 / 100; // 20% increase
        vm.prank(BIDDER_2);
        market.placeBid{value: secondBidAmount}(TOKEN_ID);

        // Check if bidder 1 was refunded
        assertEq(BIDDER_1.balance, bidder1BalanceBefore + MIN_PRICE, "Bidder 1 was not refunded");
        
        BidBeastsNFTMarket.Bid memory highestBid = market.getHighestBid(TOKEN_ID);
        assertEq(highestBid.bidder, BIDDER_2, "Bidder 2 should be the new highest bidder");
        assertEq(highestBid.amount, secondBidAmount, "New highest bid amount is incorrect");
    }

    /*//////////////////////////////////////////////////////////////
                            EXPLOIT TESTS
    //////////////////////////////////////////////////////////////*/
    function test_exploit_withdrawAllFailedCredits_drainsVictim() public {
        // Mint and list NFT by normal SELLER
        _mintNFT();
        _listNFT();

        // Deploy a bidder contract that rejects refunds
        ToggleRefundBidder victim = new ToggleRefundBidder();

        // Victim places the first bid at min price
        vm.deal(address(victim), STARTING_BALANCE);
        vm.prank(address(victim));
        victim.bid{value: MIN_PRICE}(address(market), TOKEN_ID);

        // Another user outbids, triggering refund to victim which will fail and be credited
        uint256 secondBidAmount = (MIN_PRICE * 105) / 100; // >= 5% increment
        vm.prank(BIDDER_1);
        market.placeBid{value: secondBidAmount}(TOKEN_ID);

        // Credits should now be recorded for the victim bidder
        uint256 victimCreditsBefore = market.failedTransferCredits(address(victim));
        assertGt(victimCreditsBefore, 0, "Expected failed credits for victim bidder");

        // With the fix, attacker cannot drain victim's credits
        vm.prank(BIDDER_2);
        vm.expectRevert("Not receiver");
        market.withdrawAllFailedCredits(address(victim));

        // Allow receiving ETH now for withdrawal
        victim.setRejectRefunds(false);
        // Victim can withdraw their own credits successfully
        uint256 victimBalanceBefore = address(victim).balance;
        vm.prank(address(victim));
        market.withdrawAllFailedCredits(address(victim));
        uint256 victimBalanceAfter = address(victim).balance;
        assertEq(victimBalanceAfter, victimBalanceBefore + victimCreditsBefore, "Victim did not receive their credits");

        // Credits should be cleared after successful withdrawal
        assertEq(market.failedTransferCredits(address(victim)), 0, "Credits not cleared after withdrawal");
    }

    function test_withdrawAllFailedCredits_self_withdraw_success() public {
        // Setup: cause failed refund to the RevertingBidder (as above)
        _mintNFT();
        _listNFT();

        ToggleRefundBidder victim = new ToggleRefundBidder();
        vm.deal(address(victim), STARTING_BALANCE);
        vm.prank(address(victim));
        victim.bid{value: MIN_PRICE}(address(market), TOKEN_ID);

        uint256 secondBidAmount = (MIN_PRICE * 105) / 100;
        vm.prank(BIDDER_1);
        market.placeBid{value: secondBidAmount}(TOKEN_ID);

        uint256 credits = market.failedTransferCredits(address(victim));
        assertGt(credits, 0, "Expected credits for victim");

        // Allow receiving ETH now for withdrawal
        victim.setRejectRefunds(false);
        // Positive path: victim withdraws own credits
        uint256 balBefore = address(victim).balance;
        vm.prank(address(victim));
        market.withdrawAllFailedCredits(address(victim));
        uint256 balAfter = address(victim).balance;
        assertEq(balAfter, balBefore + credits, "Self withdraw did not transfer funds");
        assertEq(market.failedTransferCredits(address(victim)), 0, "Credits should be zero after withdraw");
    }
}