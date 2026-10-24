// The Build Grant key is this runner's own: Cloud gets its public half, the holder, and answers with
// the Machine. Neither the key nor the grant is ever printed, except to mask the grant.
//   key <key file>                             writes a new ed25519 seed, prints the holder
//   holder <key file>                          prints the holder of a seed
//   assemble <check-in.json> <key> <grant file>  writes the Build Grant and masks it
'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');

// An ed25519 PKCS#8 key is this fixed prefix and the 32-byte seed.
const pkcs8 = Buffer.from('302e020100300506032b657004220420', 'hex');
const holder = (seed) => {
    const key = crypto.createPrivateKey({ key: Buffer.concat([pkcs8, seed]), format: 'der', type: 'pkcs8' });
    return Buffer.from(crypto.createPublicKey(key).export({ format: 'jwk' }).x, 'base64url').toString('hex');
};

// A parse error can quote the response, which holds build secrets: fail without a message.
try {
    const [command, ...args] = process.argv.slice(2);
    if (command === 'key') {
        const { privateKey } = crypto.generateKeyPairSync('ed25519');
        const seed = Buffer.from(privateKey.export({ format: 'jwk' }).d, 'base64url');
        fs.writeFileSync(args[0], seed, { mode: 0o600 });
        console.log(holder(seed));
    } else if (command === 'holder') {
        console.log(holder(fs.readFileSync(args[0])));
    } else if (command === 'assemble') {
        const checkIn = JSON.parse(fs.readFileSync(args[0], 'utf8'));
        let grant = checkIn.grant;
        // A Machine that mints for a holder answers with its own identity, never the grant. Older ones send the grant.
        if (checkIn.machine !== undefined) {
            if (!/^[0-9a-f]{64}$/.test(checkIn.machine)) process.exit(1);
            const seed = fs.readFileSync(args[1]);
            grant = 'ployzgrant1:' + Buffer.concat([Buffer.from(checkIn.machine, 'hex'), seed]).toString('base64url');
        }
        if (typeof grant !== 'string' || !grant.startsWith('ployzgrant1:')) process.exit(1);
        console.log(`::add-mask::${grant}`);
        fs.writeFileSync(args[2], grant, { mode: 0o600 });
    } else {
        process.exit(2);
    }
} catch {
    process.exit(1);
}
