/// @dev These are the base rules that are applied to all files.
const baseRules = {
    // Taken from OpenZeppelin/Conracts
    'avoid-tx-origin': 'error',
    'const-name-snakecase': 'error',
    'contract-name-capwords': 'error',
    'event-name-capwords': 'error',
    'max-states-count': 'error',
    'explicit-types': 'error',
    'func-param-name-mixedcase': 'error',
    'imports-on-top': 'error',
    'modifier-name-mixedcase': 'error',
    'no-console': 'error', 
    'no-global-import': 'error',
    'no-unused-vars': 'warn',
    'quotes': 'error',
    'use-forbidden-name': 'error',
    'var-name-mixedcase': 'error',
    'visibility-modifier-order': 'error',
    'interface-starts-with-i': 'error',
    'duplicated-imports': 'error',
    // Added for this project.
    'no-unused-import': 'error',
    'func-visibility': ['error', { "ignoreConstructors": true }],
    'named-parameters-mapping': 'error',
    'gas-custom-errors': 'error',
}

module.exports = {
    baseRules,
}