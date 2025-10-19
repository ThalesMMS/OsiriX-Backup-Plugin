const fs = require('fs');
const path = require('path');

// --- Configuração ---
const projectRoot = path.resolve(__dirname, '..');
const outputFileName = 'all_project_code.txt';
const filesToInclude = [
    path.join('Sources', 'Swift', 'Core', 'Plugin.swift'),
    path.join('Sources', 'Swift', 'OsiriXBackupController.swift'),
    path.join('Sources', 'Swift', 'Core', 'OsiriXBackup.swift'),
    path.join('Resources', 'Info.plist'),
    path.join('Resources', 'Settings.xib') // Nota: Este é um arquivo XML que define a UI.
];
// --- Fim da Configuração ---

const outputFilePath = path.join(projectRoot, outputFileName);
let allContent = [];

console.log('Iniciando a coleta de arquivos de código...');

filesToInclude.forEach(fileName => {
    const filePath = path.join(projectRoot, fileName);
    try {
        if (fs.existsSync(filePath)) {
            console.log(`Lendo o arquivo: ${fileName}`);
            const content = fs.readFileSync(filePath, 'utf8');
            allContent.push(`// --- File: ${fileName} ---`);
            allContent.push(content);
            allContent.push(`// --- End of file: ${fileName} ---\n\n`);
        } else {
            console.warn(`AVISO: Arquivo não encontrado e será ignorado: ${fileName}`);
            allContent.push(`// --- File: ${fileName} (NÃO ENCONTRADO) ---\n\n`);
        }
    } catch (error) {
        console.error(`ERRO ao ler o arquivo ${fileName}: ${error.message}`);
        allContent.push(`// --- File: ${fileName} (ERRO AO LER) ---\n\nError: ${error.message}\n\n`);
    }
});

try {
    fs.writeFileSync(outputFilePath, allContent.join('\n'));
    console.log(`\nSucesso! Conteúdo dos arquivos foi salvo em: ${outputFilePath}`);
} catch (error) {
    console.error(`ERRO ao escrever o arquivo de saída ${outputFileName}: ${error.message}`);
}