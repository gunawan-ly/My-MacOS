#!/usr/bin/env node
/**
 * upload_artifact.js — Upload file sebagai artifact GitHub Actions dari dalam step yang sedang berjalan.
 * Menggunakan @actions/artifact resmi.
 *
 * Penggunaan: node upload_artifact.js <nama-artifact> <path-file> [path-file2 ...]
 */
const artifact = require('@actions/artifact');
const path = require('path');

async function main() {
    const args = process.argv.slice(2);
    if (args.length < 2) {
        console.error('Penggunaan: node upload_artifact.js <nama> <file...>');
        process.exit(1);
    }
    const name = args[0];
    const files = args.slice(1);
    const rootDir = path.dirname(files[0]);

    const client = artifact.create();
    try {
        const result = await client.uploadArtifact(name, files, rootDir, {
            retentionDays: 1,
        });
        console.log(`Artifact '${name}' diupload: ${result.size} bytes, ${result.artifactItems.length} file`);
    } catch (err) {
        console.error('Upload gagal:', err.message);
        process.exit(1);
    }
}

main();
