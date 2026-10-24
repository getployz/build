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
// Each refusal is a fixed line that names no secret.
class Refusal extends Error {}
const readSeed = (path) => {
    const seed = fs.readFileSync(path);
    if (seed.length !== 32) throw new Refusal('The Build Grant key is not 32 bytes.');
    return seed;
};
// A fresh file, so 0600 holds even when one was already there.
const writeSecret = (path, data) => {
    fs.rmSync(path, { force: true });
    fs.writeFileSync(path, data, { mode: 0o600, flag: 'wx' });
};

// A parse error can quote the response, which holds build secrets: print only fixed lines.
try {
    const [command, ...args] = process.argv.slice(2);
    if (command === 'key') {
        const { privateKey } = crypto.generateKeyPairSync('ed25519');
        const seed = Buffer.from(privateKey.export({ format: 'jwk' }).d, 'base64url');
        writeSecret(args[0], seed);
        console.log(holder(seed));
    } else if (command === 'holder') {
        console.log(holder(readSeed(args[0])));
    } else if (command === 'assemble') {
        let checkIn;
        try {
            checkIn = JSON.parse(fs.readFileSync(args[0], 'utf8'));
        } catch {
            throw new Refusal('Check-in response has no Build Grant.');
        }
        let grant = checkIn.grant;
        // A Machine that mints for a holder answers with its own identity, never the grant. Older ones send the grant.
        if (checkIn.machine !== undefined) {
            if (!/^[0-9a-f]{64}$/.test(checkIn.machine)) throw new Refusal('Check-in response has no valid Machine.');
            const seed = readSeed(args[1]);
            grant = 'ployzgrant1:' + Buffer.concat([Buffer.from(checkIn.machine, 'hex'), seed]).toString('base64url');
        }
        if (typeof grant !== 'string' || !grant.startsWith('ployzgrant1:')) throw new Refusal('Check-in response has no Build Grant.');
        console.log(`::add-mask::${grant}`);
        writeSecret(args[2], grant);
    } else {
        process.exit(2);
    }
} catch (error) {
    console.log(`::error::${error instanceof Refusal ? error.message : 'The Build Grant key could not be made or read.'}`);
    process.exit(1);
}
