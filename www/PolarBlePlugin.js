var exec = require('cordova/exec');

var PolarBlePlugin = {
	connect: function (arg0, success, error) {
        exec(success, error, 'PolarBlePlugin', 'connect', [arg0]);
    },
	disconnect: function (arg0, success, error) {
        exec(success, error, 'PolarBlePlugin', 'disconnect', [arg0]);
    },
    setCallback: function (arg0, arg1, success, error) {
        exec(success, error, 'PolarBlePlugin', 'setCallback', [arg0, arg1]);
    },
	echo: function (arg0, success, error) {
        exec(success, error, 'PolarBlePlugin', 'echo', [arg0]);
    }
};


module.exports = PolarBlePlugin;