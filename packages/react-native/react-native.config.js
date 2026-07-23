'use strict';

module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
        packageImportPath: 'import ai.onlo.reactnative.OnloSDKPackage;',
        packageInstance: 'new OnloSDKPackage()',
      },
      ios: {},
    },
  },
};
