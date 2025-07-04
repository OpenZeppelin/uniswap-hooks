const customRules = require('solhint-plugin-openzeppelin');
const { baseRules } = require('./solhint.base.config');

/// @dev Rules that are only relevant for src files.
const srcOnlyRules = {
  'private-vars-leading-underscore': 'error',
  'func-name-mixedcase': 'error', 
  'state-visibility': 'error',
  // 'ordering', convolutes the pr.
}

module.exports = {
  plugins: ['openzeppelin'],
  rules: { 
    ...Object.fromEntries(customRules.map(r => [`openzeppelin/${r.ruleId}`, 'error'])),
    ...baseRules,
    ...srcOnlyRules,
  },
};
