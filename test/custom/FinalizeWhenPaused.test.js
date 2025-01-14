// SPDX-License-Identifier: MIT
// ============ External Imports ============
const { waffle } = require('hardhat');
const { provider } = waffle;
const { expect } = require('chai');
const BigNumber = require('bignumber.js');
// ============ Internal Imports ============
const {
  eth,
  weiToEth,
  getTotalContributed,
  contribute,
  bidThroughParty,
} = require('../helpers/utils');
const { placeBid } = require('../helpers/externalTransactions');
const { deployTestContractSetup, getTokenVault } = require('../helpers/deploy');
const {
  PARTY_STATUS,
  FOURTY_EIGHT_HOURS_IN_SECONDS,
} = require('../helpers/constants');
const { testCases } = require('../partybid/partyBidTestCases.json');
const {
  MARKETS,
  MARKET_NAMES,
  TOKEN_FEE_BASIS_POINTS,
  ETH_FEE_BASIS_POINTS,
  TOKEN_SCALE,
} = require('../helpers/constants');

describe.only('Finalize When Paused', async () => {
  MARKETS.filter((m) => m == MARKET_NAMES.NOUNS || m == MARKET_NAMES.KOANS).map(
    (marketName) => {
      describe(marketName, async () => {
        testCases.map((testCase, i) => {
          describe(`Case ${i}`, async () => {
            // get test case information
            const {
              auctionReservePrice,
              splitRecipient,
              splitBasisPoints,
              contributions,
              bids,
              finalBid,
            } = testCase;
            // instantiate test vars
            let partyBid,
              market,
              nftContract,
              partyDAOMultisig,
              auctionId,
              multisigBalanceBefore,
              token;
            const lastBid = bids[bids.length - 1];
            const partyBidWins = lastBid.placedByPartyBid && lastBid.success;
            const signers = provider.getWallets();
            const tokenId = 95;
            // total contributed
            const totalContributed = new BigNumber(
              getTotalContributed(contributions),
            );
            // final bid
            const finBid = new BigNumber(finalBid[marketName]);
            // token fee
            const tokenFeeBps = new BigNumber(TOKEN_FEE_BASIS_POINTS);
            const tokenFeeFactor = tokenFeeBps.div(10000);
            // ETH fee
            const ethFeeBps = new BigNumber(ETH_FEE_BASIS_POINTS);
            const ethFeeFactor = ethFeeBps.div(10000);
            // token recipient
            const splitRecipientBps = new BigNumber(splitBasisPoints);
            const splitRecipientFactor = splitRecipientBps.div(10000);
            // ETH fee + total ETH spent
            const ethFee = finBid.times(ethFeeFactor);
            const expectedTotalSpent = finBid.plus(ethFee);

            before(async () => {
              // DEPLOY NFT, MARKET, AND PARTY BID CONTRACTS
              const contracts = await deployTestContractSetup(
                marketName,
                provider,
                signers[0],
                splitRecipient,
                splitBasisPoints,
                auctionReservePrice,
                tokenId,
                false,
                true, // Pause the auction house
              );
              partyBid = contracts.partyBid;
              market = contracts.market;
              partyDAOMultisig = contracts.partyDAOMultisig;
              nftContract = contracts.nftContract;

              auctionId = await partyBid.auctionId();

              multisigBalanceBefore = await provider.getBalance(
                partyDAOMultisig.address,
              );

              // submit contributions before bidding begins
              for (let contribution of contributions) {
                const { signerIndex, amount } = contribution;
                const signer = signers[signerIndex];
                await contribute(partyBid, signer, eth(amount));
              }

              // submit the valid bids in order
              for (let bid of bids) {
                const { placedByPartyBid, amount, success } = bid;
                if (success && placedByPartyBid) {
                  const { signerIndex } = contributions[0];
                  await bidThroughParty(partyBid, signers[signerIndex]);
                } else if (success && !placedByPartyBid) {
                  await placeBid(
                    signers[0],
                    market,
                    auctionId,
                    eth(amount),
                    marketName,
                  );
                }
              }
            });

            it('Does not allow Finalize before the auction is over', async () => {
              await expect(partyBid.finalize()).to.be.reverted;
            });

            it('Is ACTIVE before Finalize', async () => {
              const partyStatus = await partyBid.partyStatus();
              expect(partyStatus).to.equal(PARTY_STATUS.ACTIVE);
            });

            it('Does allow Finalize after the auction is over', async () => {
              // increase time on-chain so that auction can be finalized
              await provider.send('evm_increaseTime', [
                FOURTY_EIGHT_HOURS_IN_SECONDS,
              ]);
              await provider.send('evm_mine');

              // finalize auction
              await expect(partyBid.finalize()).to.emit(partyBid, 'Finalized');
            });

            it(`Doesn't accept contributions after Finalize`, async () => {
              await expect(
                contribute(partyBid, signers[0], eth(1)),
              ).to.be.revertedWith('Party::contribute: party not active');
            });

            it(`Doesn't accept bids after Finalize`, async () => {
              await expect(
                bidThroughParty(partyBid, signers[0]),
              ).to.be.revertedWith('PartyBid::bid: auction not active');
            });

            if (partyBidWins) {
              it(`Is WON after Finalize`, async () => {
                const partyStatus = await partyBid.partyStatus();
                expect(partyStatus).to.equal(PARTY_STATUS.WON);
              });

              it('Has correct totalSpent', async () => {
                const totalSpent = await partyBid.totalSpent();
                expect(weiToEth(totalSpent)).to.equal(
                  expectedTotalSpent.toNumber(),
                );
              });

              it(`Transferred ETH fee to multisig`, async () => {
                const balanceBefore = new BigNumber(
                  weiToEth(multisigBalanceBefore),
                );
                const expectedBalanceAfter = balanceBefore.plus(ethFee);
                const multisigBalanceAfter = await provider.getBalance(
                  partyDAOMultisig.address,
                );
                expect(weiToEth(multisigBalanceAfter)).to.equal(
                  expectedBalanceAfter.toNumber(),
                );
              });

              it('Has correct balance of ETH in PartyBid', async () => {
                const expectedEthBalance =
                  totalContributed.minus(expectedTotalSpent);
                const ethBalance = await provider.getBalance(partyBid.address);
                expect(weiToEth(ethBalance)).to.equal(
                  expectedEthBalance.toNumber(),
                );
              });
            } else {
              it(`Is LOST after Finalize`, async () => {
                const partyStatus = await partyBid.partyStatus();
                expect(partyStatus).to.equal(PARTY_STATUS.LOST);
              });

              it(`Does not own the NFT`, async () => {
                const owner = await nftContract.ownerOf(tokenId);
                expect(owner).to.not.equal(partyBid.address);
              });

              it('Has zero totalSpent', async () => {
                const totalSpent = await partyBid.totalSpent();
                expect(totalSpent).to.equal(0);
              });

              it(`Did not transfer fee to multisig`, async () => {
                const multisigBalanceAfter = await provider.getBalance(
                  partyDAOMultisig.address,
                );
                expect(multisigBalanceAfter).to.equal(multisigBalanceBefore);
              });
            }
          });
        });
      });
    },
  );
});
