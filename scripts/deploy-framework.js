const { web3tx } = require("@decentral.ee/web3-helpers");
const SuperfluidSDK = require("..");

const TestResolver = artifacts.require("TestResolver");
const Superfluid = artifacts.require("Superfluid");
const SuperToken = artifacts.require("SuperToken");
const SuperTokenMock = artifacts.require("SuperTokenMock");
const TestGovernance = artifacts.require("TestGovernance");
const Proxy = artifacts.require("Proxy");
const Proxiable = artifacts.require("Proxiable");
const ConstantFlowAgreementV1 = artifacts.require("ConstantFlowAgreementV1");
const InstantDistributionAgreementV1 = artifacts.require("InstantDistributionAgreementV1");

const {
    hasCode,
    codeChanged,
    proxiableCodeChanged
} = require("./utils");


/**
 * @dev Deploy the superfluid framework
 *
 * Usage: npx truffle exec scripts/deploy-framework.js
 */
module.exports = async function (callback) {
    try {
        global.web3 = web3;

        const accounts = await web3.eth.getAccounts();

        const reset = !!process.env.RESET;
        const version = process.env.RELEASE_VERSION || "test";
        const chainId = await web3.eth.net.getId(); // FIXME use eth.getChainId;
        console.log("reset: ", reset);
        console.log("network ID: ", chainId);
        console.log("release version:", version);
        process.env.USE_MOCKS && console.log("**** !ATTN! USING MOCKS CONTRACTS ****");

        const config = SuperfluidSDK.getConfig(chainId);

        let testResolver;
        if (config.resolverAddress) {
            testResolver = await TestResolver.at(config.resolverAddress);
        } else {
            testResolver = await web3tx(TestResolver.new, "TestResolver.new")();
            // make it available for the sdk for testing purpose
            process.env.TEST_RESOLVER_ADDRESS = testResolver.address;
        }
        console.log("Resolver address", testResolver.address);

        // deploy Superfluid
        let superfluid;
        {
            const name = `Superfluid.${version}`;
            let superfluidAddress = await testResolver.get(name);
            console.log("Superfluid address", superfluidAddress);
            if (reset || !await hasCode(superfluidAddress)) {
                const proxy = await web3tx(Proxy.new, "Create Superfluid proxy")();
                superfluidAddress = proxy.address;
                const superfluidLogic = await web3tx(Superfluid.new, "Superfluid.new")();
                console.log(`Superfluid new code address ${superfluidLogic.address}`);
                await web3tx(proxy.initializeProxy, "proxy.initializeProxy")(
                    superfluidLogic.address
                );
                superfluid = await Superfluid.at(proxy.address);
                await web3tx(superfluid.initialize, "Superfluid.initialize")();
                await web3tx(testResolver.set, `TestResolver set ${name}`)(
                    name, proxy.address
                );
                console.log("Superfluid address", superfluidAddress);
            } else {
                if (await proxiableCodeChanged(Proxiable, Superfluid, superfluidAddress)) {
                    const superfluidLogic = await web3tx(Superfluid.new,
                        "Superfluid.new due to code change")();
                    console.log(`Superfluid new code address ${superfluidLogic.address}`);
                    superfluid = await Superfluid.at(superfluidAddress);
                    await web3tx(superfluid.updateCode, "superfluid.updateCode")(
                        superfluidLogic.address
                    );
                } else {
                    console.log("Superfluid has the same logic code, no deployment needed.");
                }
            }
            superfluid = await Superfluid.at(superfluidAddress);
            process.env.TEST_SUPERFLUID_ADDRESS = superfluidAddress;
        }

        // deploy TestGovernance
        let governance;
        {
            const name = `TestGovernance.${version}`;
            const governanceAddress = await testResolver.get(name);
            console.log("TestGovernance address", governanceAddress);
            if (reset || await codeChanged(TestGovernance, governanceAddress)) {
                governance = await web3tx(TestGovernance.new, "TestGovernance.new due to code change")(
                    accounts[0], // rewardAddress
                    3600, // liquidationPeriod
                );
                console.log("TestGovernance address", governance.address);
                await web3tx(testResolver.set, `TestResolver set ${name}`)(
                    name, governance.address
                );
            } else {
                governance = await TestGovernance.at(governanceAddress);
                console.log("TestGovernance has the same code, no deployment needed.");
            }
        }
        if ((await superfluid.getGovernance.call()) !== governance.address){
            await web3tx(superfluid.setGovernance, "superfluid.setGovernance")(
                governance.address
            );
        }

        // deploy ConstantFlowAgreementV1
        {
            const agreementType = web3.utils.sha3("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
            const isListed = await superfluid.isAgreementTypeListed.call(agreementType);
            const isChanged = !isListed || await codeChanged(
                ConstantFlowAgreementV1,
                await (await Proxiable.at(await superfluid.getAgreementClass.call(agreementType))).getCodeAddress()
            );
            console.log(`ConstantFlowAgreementV1 isListed ${isListed} isChanged ${isChanged}`);
            if (reset || !isListed || isChanged) {
                const agreement = await web3tx(
                    ConstantFlowAgreementV1.new,
                    "ConstantFlowAgreementV1.new")();
                console.log("New ConstantFlowAgreementV1 address", agreement.address);
                if (reset || !isListed) {
                    await web3tx(governance.registerAgreementClass, "Governance registers CFA")(
                        superfluid.address,
                        agreement.address
                    );
                } else {
                    await web3tx(governance.updateAgreementClass, "Governance updates CFA code")(
                        superfluid.address,
                        agreement.address
                    );
                }
            } else {
                console.log("ConstantFlowAgreementV1 has the same code, no deployment needed");
            }
        }

        // deploy InstantDistributionAgreementV1
        {
            const agreementType = web3.utils.sha3("org.superfluid-finance.agreements.InstantDistributionAgreement.v1");
            const isListed = await superfluid.isAgreementTypeListed.call(agreementType);
            const isChanged = !isListed || await codeChanged(
                InstantDistributionAgreementV1,
                await (await Proxiable.at(await superfluid.getAgreementClass.call(agreementType))).getCodeAddress()
            );
            console.log(`InstantDistributionAgreementV1 isListed ${isListed} isChanged ${isChanged}`);
            if (reset || !isListed || isChanged) {
                const agreement = await web3tx(
                    InstantDistributionAgreementV1.new,
                    "InstantDistributionAgreementV1.new")();
                console.log("New InstantDistributionAgreementV1 address", agreement.address);
                if (reset || !isListed) {
                    await web3tx(governance.registerAgreementClass, "Governance registers IDA")(
                        superfluid.address,
                        agreement.address
                    );
                } else {
                    await web3tx(governance.updateAgreementClass, "Governance updates IDA code")(
                        superfluid.address,
                        agreement.address
                    );
                }
            } else {
                console.log("InstantDistributionAgreementV1 has the same code, no deployment needed");
            }
        }

        let superTokenLogicAddress;
        {
            superTokenLogicAddress = await superfluid.getSuperTokenLogic.call();
            console.log("SuperTokenLogic address", superTokenLogicAddress);
            const SuperTokenLogic = process.env.USE_MOCKS ? SuperTokenMock : SuperToken;
            if (reset || await codeChanged(SuperTokenLogic, superTokenLogicAddress)) {
                const superTokenLogic = await web3tx(SuperTokenLogic.new, "SuperToken.new due to code change")();
                superTokenLogicAddress = superTokenLogic.address;
                console.log("SuperTokenLogic address", superTokenLogicAddress);
                await web3tx(superfluid.setSuperTokenLogic, "superfluid.setSuperTokenLogic")(
                    superTokenLogicAddress
                );
            } else {
                console.log("SuperTokenLogic has the same code, no deployment needed.");
            }
        }

        callback();
    } catch (err) {
        callback(err);
    }
};
