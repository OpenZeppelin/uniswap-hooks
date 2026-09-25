// This Hardhat config is used for generating documentation only.
require('solidity-docgen');
const { subtask } = require('hardhat/config');
const { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } = require('hardhat/builtin-tasks/task-names');

// Mocks are excluded from the documentation (see docs/config.js) and import OpenZeppelin test mocks
// that are not published to npm, so they are skipped here rather than compiled.
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS, async (_, __, runSuper) =>
  (await runSuper()).filter((sourcePath) => !sourcePath.includes('/src/mocks/')),
);

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: "0.8.26",
    settings: {
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "src",
    cache: "cache_hardhat",
  },
  docgen: require('./docs/config'),
};
