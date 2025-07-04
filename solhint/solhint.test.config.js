const customRules = require('solhint-plugin-openzeppelin');
const { baseRules } = require('./solhint.base.config');

/// @dev Rules that are only relevant for test files.
const testOnlyRules = {
  // 'foundry-test-functions': 'error',
}

module.exports = {
  plugins: ['openzeppelin'],
  rules: { 
    ...Object.fromEntries(customRules.map(r => [`openzeppelin/${r.ruleId}`, 'error'])),
    ...baseRules,
    ...testOnlyRules,
  },
};
