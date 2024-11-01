/**
 * Main Program
 */
async function main () {
    /* Initialize contract. */
    const Box = await ethers.getContractFactory('Box')
    console.log('\n  Deploying Box...')

    /* Deploy contract. */
    const box = await Box.deploy()

    /* Wait for deployment (and on-chain confirmation). */
    await box.waitForDeployment()
    console.log('\n  Box deployed to:', await box.getAddress())
    console.log()
}

/* Execute Main (and handle errors). */
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error)
        process.exit(1)
    })
