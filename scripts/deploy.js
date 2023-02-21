/* global ethers */
/* eslint prefer-const: "off" */

const { getSelectors, FacetCutAction } = require('./libraries/diamond.js')

const { deployAutoFarmV2Diamond } = require('./deploy-autofarmv2.js')
const { deployStratX2Diamond } = require('./deploy-stratx2.js')

async function deployDiamond () {
  const autofarmv2 = await deployAutoFarmV2Diamond();
  const stratx2 = await deployStratX2Diamond();

  return [autofarmv2, stratx2];
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
if (require.main === module) {
  deployDiamond()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error)
      process.exit(1)
    })
}

module.exports = { deployDiamond } 
