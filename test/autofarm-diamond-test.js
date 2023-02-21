/* global describe it before ethers */

const { deployDiamond } = require('../scripts/deploy.js')

const { expect } = require('chai')
const { ethers } = require('hardhat')
const { BigNumber } = require('ethers')

describe('AutoFarmV2-Diamond-Standard-Test', async function () {
      let owner
      let addr1
      let addr2
      let diamondAddres1
      let diamondAddres2
      let diamondCutFacet
      let diamondCutFacet2
      let diamondLoupeFacet
      let diamondLoupeFacet2
      let token1

      before(async function () {

            [owner, addr1, addr2] = await ethers.getSigners();

            [diamondAddres1, diamondAddres2] = await deployDiamond()
            diamondCutFacet = await ethers.getContractAt('DiamondCutFacet', diamondAddres1)
            diamondLoupeFacet = await ethers.getContractAt('DiamondLoupeFacet', diamondAddres1)
            ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddres1)
            autofarmV2Facet = await ethers.getContractAt('AutoFarmV2Facet', diamondAddres1)

            stratX2Facet = await ethers.getContractAt('StratX2Facet', diamondAddres2)
            diamondCutFacet2 = await ethers.getContractAt('DiamondCutFacet', diamondAddres2)
            diamondLoupeFacet2 = await ethers.getContractAt('DiamondLoupeFacet', diamondAddres2)

            const MyToken1 = await ethers.getContractFactory("MyToken1");
            token1 = await MyToken1.deploy();
            await token1.deployed();


            // Deploy DiamondInit.sol
            const DiamondInit = await ethers.getContractFactory("DiamondInit");
            const diamondInit = await DiamondInit.deploy();
            await diamondInit.deployed();

            // deploy AUTOv2 token
            const AUTOv2 = await ethers.getContractFactory("AUTOv2");
            const autov2 = await AUTOv2.deploy();
            await autov2.deployed();

            // setting values in autofarminit and stratxinit functions
            let autoV2InitFunctionCall = diamondInit.interface.encodeFunctionData('autofarmV2Init', [autov2.address]);
            let startx2InitFunctionCall = diamondInit.interface.encodeFunctionData('stratX2Init', [diamondAddres1, token1.address]);

            await diamondCutFacet.diamondCut(
                  [],   //cut
                  diamondInit.address,
                  autoV2InitFunctionCall
            )
            await diamondCutFacet2.diamondCut(
                  [],   //cut
                  diamondInit.address,
                  startx2InitFunctionCall
            )
      })

      it('diamond1 should have 4 facets -- call to facetAddresses function', async () => {

            const faccetAddresses = await diamondLoupeFacet.facetAddresses();
            expect(faccetAddresses.length).to.equal(4);

      })

      it('diamond2 should have 4 facets -- call to facetAddresses function', async () => {

            const faccetAddresses = await diamondLoupeFacet2.facetAddresses();
            expect(faccetAddresses.length).to.equal(4);

      })

      it("only owner can add tokens in pool", async function () {

            await expect(autofarmV2Facet.connect(addr1).add(
                  1000000,
                  token1.address,
                  true,
                  diamondAddres2
            )).to.be.reverted;

      })

      it("owner will add token1 in pools", async function () {

            await autofarmV2Facet.add(
                  1000000,
                  token1.address,
                  true,
                  diamondAddres2
            );

            expect(await autofarmV2Facet.poolLength()).to.equal(1);

      })

      it("updating pool 0", async function () {

            await autofarmV2Facet.set(
                  0,
                  10000000,
                  true
            );

            const [, allockPoint, , ,] = await autofarmV2Facet.poolInfo(0);
            await expect(allockPoint).to.equal(10000000);

      })

      it("only owner can update pool", async function () {

            await expect(autofarmV2Facet.connect(addr1).set(
                  0,
                  100000,
                  true
            )).to.be.reverted;

      })

      it("depositing in pool id 0", async function () {

            await token1.mint(addr1.address, BigNumber.from("100000000000000000000"));
            expect(await token1.balanceOf(addr1.address)).to.equal(BigNumber.from("100000000000000000000"));

            await token1.connect(addr1).approve(autofarmV2Facet.address, BigNumber.from("1000000000000000000"));
            await autofarmV2Facet.connect(addr1).deposit(0, BigNumber.from("1000000000000000000"));

            const [shares,] = await autofarmV2Facet.userInfo(0, addr1.address);
            expect(shares).to.equal(BigNumber.from("1000000000000000000"));

      });

      it("can not deposit to a pool which is not created", async function () {

            await token1.connect(addr1).approve(autofarmV2Facet.address, BigNumber.from("1000000000000000000"));
            await expect(autofarmV2Facet.connect(addr1).deposit(1, BigNumber.from("1000000000000000000"))).to.be.reverted;

      });

      it("can not withdraw without deposit", async function () {
            await expect(autofarmV2Facet.connect(addr2).withdraw(0, BigNumber.from("1000000000000000000"))).to.be.reverted;
      });

      it("withdraw from pool id 0", async function () {

            await autofarmV2Facet.connect(addr1).withdraw(0, BigNumber.from("1000000000000000000"));

            const [shares,] = await autofarmV2Facet.userInfo(0, addr1.address);
            expect(shares).to.equal(0);

            expect(await token1.balanceOf(addr1.address)).to.equal(BigNumber.from("100000000000000000000"));

      });

      it("withdaw all ", async function () {

            await token1.connect(addr1).approve(autofarmV2Facet.address, BigNumber.from("1000000000000000000"));
            await autofarmV2Facet.connect(addr1).deposit(0, BigNumber.from("1000000000000000000"));

            await autofarmV2Facet.connect(addr1).withdrawAll(0);

            const [shares,] = await autofarmV2Facet.userInfo(0, addr1.address);
            expect(shares).to.equal(0);
            expect(await token1.balanceOf(addr1.address)).to.equal(BigNumber.from("100000000000000000000"));

      });

      it("emergency withdraw ", async function () {

            await token1.connect(addr1).approve(autofarmV2Facet.address, BigNumber.from("1000000000000000000"));
            await autofarmV2Facet.connect(addr1).deposit(0, BigNumber.from("1000000000000000000"));

            await autofarmV2Facet.connect(addr1).emergencyWithdraw(0);

            const [shares,] = await autofarmV2Facet.userInfo(0, addr1.address);
            expect(shares).to.equal(0);
            expect(await token1.balanceOf(addr1.address)).to.equal(BigNumber.from("100000000000000000000"));

      });


})