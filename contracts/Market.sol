//"SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import './Interfaces/IArbitrator.sol';      //See ERC 792
import './Interfaces/IArbitrable.sol';
import './Interfaces/IEvidence.sol';

contract PackitMarket is IArbitrable, IEvidence {


    //Data structures for the contract

    IArbitrator public arbitrator;

    address payable arbitratorAddress;

    uint RulingOptionsNumber = 2;
    uint arbitrationWindow = 3 days;

    enum TxStatus {Initialized, Pending, Successful, Disputed, Resolved}
    enum RulingOptions {RefusedToArbitrate, CustomerWins, VendorWins}

    struct Receipt {

        address payable vendor;
        address payable customer;
        uint price;

        uint initialized;
        TxStatus status;

        bytes32 productHash;
        uint receiptID;

        uint disputeID;
        bool customerDispute;
        bool vendorDispute;

        uint arbitrationInit;
        uint shippingInit;
        uint shippingWindow;
    }

    struct Product {
        address payable vendor;
        bool forSale;
    }

    Receipt[] allTransactions;

    mapping(bytes32 => uint[]) receiptIDs;              // produtHash to its set of receiptIDs
    mapping(bytes32 => Product) productDetails;         // productHash to details about that product
    mapping(bytes32 => bool) productAvailability;       // productHash to bool (whether the product exists on Packit or not)
    mapping(uint => uint) public disputeToReceipt;      // disputeID to receiptID

    receive() external payable {

    }

    constructor(address payable _arbitratorAddress) {
        arbitratorAddress = _arbitratorAddress;
        arbitrator = IArbitrator(arbitratorAddress);
    }

    // Product registration
    function registerProduct(address payable _vendor, bytes32 _productHash) public {
        require(!(productAvailability[_productHash]), "You cannnot register a product that is already registered on Packit.");

        Product memory newProduct = Product({
            vendor: _vendor,
            forSale: true
        });

        productAvailability[_productHash] = true;
        productDetails[_productHash] = newProduct;
        
    }

    //Making a purchase
    function verifyProduct(address payable _vendor, bytes32 _productHash) internal view returns(bool) {
        return productDetails[_productHash].forSale && productDetails[_productHash].vendor == _vendor;
    }

    function purchase(address payable _vendor, uint _price, bytes32 _productHash,  string memory _metaevidence) public payable {
        
        require(msg.value == _price, "Amount sent is incorrect for the purchase.");
        require(verifyProduct(_vendor, _productHash), "The product does not match any product on Packit.");

        uint _receiptID = allTransactions.length;
        emit MetaEvidence(_receiptID, _metaevidence);

        Receipt memory newReceipt = Receipt({
            vendor: _vendor,
            customer: msg.sender,
            price: _price,

            initialized: block.timestamp,
            status: TxStatus.Initialized,

            productHash: _productHash,
            receiptID: _receiptID,

            disputeID: 0,
            customerDispute: false,
            vendorDispute: false,

            arbitrationInit: 0,
            shippingInit: 0,
            shippingWindow: 0
        });

        allTransactions.push(newReceipt);
        receiptIDs[_productHash].push(_receiptID);
    }

    // Sale mechanics (vendor / customer confirmation)

    // Stage 1: vendor engages in sale
    function vendorConfirm(uint _receiptID, uint _shippingWindow) external {

        Receipt storage receipt = allTransactions[_receiptID];
        require(receipt.vendor == msg.sender, "Only the vendor of this product can engage in its sale.");
        require(receipt.status == TxStatus.Initialized, "Vendor can only confirm an initial transaction.");

        receipt.status = TxStatus.Pending;
        receipt.shippingInit = block.timestamp;
        receipt.shippingWindow = _shippingWindow;
    }

    // Stage 2: customer confirms product as received
    function customerConfirm(uint _receiptID) external {
        Receipt storage receipt = allTransactions[_receiptID];
        require(receipt.customer == msg.sender, "Only the customer of this product can engage in its sale.");

        receipt.status = TxStatus.Successful;
        releaseFunds(_receiptID);
    }

    // Movement of funds
    function releaseFunds(uint receiptID) internal {
    
        Receipt storage receipt = allTransactions[receiptID];
        require(msg.sender == receipt.customer, "Only the customer can release funds.");
        require(receipt.status == TxStatus.Pending, "The transaction is not in progress.");

        bool success = receipt.vendor.send(receipt.price);
        require(success);
    }

    function customerReclaimFunds(uint receiptID) external {
        Receipt storage receipt = allTransactions[receiptID];
        require(msg.sender == receipt.customer, "Only the customer can reclaim funds.");
        require(receipt.status == TxStatus.Initialized, "The transaction is not in progress.");
        require(block.timestamp - receipt.initialized > 1 days, "The vendor has one full day to engage in the sale.");

        receipt.status = TxStatus.Resolved;

        bool success = receipt.customer.send(receipt.price);
        require(success);
    }

    function vendorClaimFunds(uint receiptID) external {

        Receipt storage receipt = allTransactions[receiptID];
        require(msg.sender == receipt.vendor, "Only the vendor can claim funds.");
        require(receipt.status == TxStatus.Pending, "The transaction must be in progress.");
        require(block.timestamp - receipt.shippingInit > receipt.shippingWindow + 3 days, "Cannot claim funds in the waiting period.");

        receipt.status = TxStatus.Successful;

        bool success = receipt.vendor.send(receipt.price);
        require(success);
    }


    // Dispute resolution (funcitons for 'Arbitrable' from ERC 792)
    function dispute(uint receiptID, string memory _evidence) external payable {
        require(msg.value == arbitrator.arbitrationCost('')/2, "Need to pay the required dispute fee.");

        Receipt storage receipt = allTransactions[receiptID];
        require(block.timestamp - receipt.initialized > 1 days, "You need to wait for a day before you can dispute.");
        require(msg.sender == receipt.vendor || msg.sender == receipt.customer, "You must be a part of the transaciton to dispute it.");

        if(msg.sender == receipt.customer) {
            require(!receipt.customerDispute, "Cannot dispute the same transaction twice.");
        } else if (msg.sender == receipt.vendor) {
            require(!receipt.vendorDispute, "Cannot dispute the same transaction twice.");
        }

        if(receipt.status == TxStatus.Disputed) {
            require(block.timestamp - receipt.arbitrationInit > arbitrationWindow, "Sorry, the dispute window has passed.");
            
            uint cost = arbitrator.arbitrationCost('');
            receipt.disputeID = arbitrator.createDispute{value: cost}(RulingOptionsNumber, '');
            disputeToReceipt[receipt.disputeID] = receiptID;

            emit Dispute(arbitrator, receipt.disputeID, receiptID, receiptID);

        } else {
            require(receipt.status == TxStatus.Pending, "Can only dispute when the transaction is pending.");
            receipt.status = TxStatus.Disputed;
            receipt.arbitrationInit = block.timestamp; 

            if(msg.sender == receipt.customer) {
                receipt.customerDispute = true;
            } else {
                receipt.vendorDispute = true;
            }
            
        }
        
        emit Evidence(arbitrator, _receiptID, msg.sender, _evidence);
    }

    function rule(uint _disputeID, uint _ruling) public override {
        require(msg.sender == arbitratorAddress, "Only the arbitrator can give a ruling on the matter.");
        require(_ruling <= RulingOptionsNumber, "Invalid ruling option.");
        
        uint receiptID = disputeToReceipt[_disputeID];
        Receipt storage receipt = allTransactions[receiptID];

        receipt.status = TxStatus.Resolved;

        uint amount = receipt.price + arbitrator.arbitrationCost('');

        if( _ruling == uint(RulingOptions.CustomerWins) ) {
            bool success = receipt.customer.send(amount);
            require(success);
        } else if( _ruling == uint(RulingOptions.VendorWins) ) {
            bool success = receipt.vendor.send(amount);
            require(success);
        }

        emit Ruling(arbitrator, _disputeID, _ruling);
    }
}
