import os

def listar_estrutura(pasta_inicial="."):
    """
    Lista a estrutura de pastas e arquivos a partir da pasta especificada.

    Args:
        pasta_inicial (str): O caminho da pasta inicial. O padrão é a pasta atual (".").
    """
    nome_arquivo = "estrutura_pastas.txt"
    with open(nome_arquivo, "w", encoding="utf-8") as arquivo:
        for raiz, pastas, arquivos in os.walk(pasta_inicial):
            # Escreve o caminho da pasta atual
            arquivo.write(f"Pasta: {raiz}\n")

            # Escreve as subpastas
            for pasta in pastas:
                arquivo.write(f"  Subpasta: {pasta}\n")

            # Escreve os arquivos
            for arquivo_nome in arquivos:
                arquivo.write(f"  Arquivo: {arquivo_nome}\n")

            arquivo.write("-" * 40 + "\n")  # Adiciona uma linha separadora

    print(f"Estrutura de pastas e arquivos salva em '{nome_arquivo}'")

if __name__ == "__main__":
    listar_estrutura()