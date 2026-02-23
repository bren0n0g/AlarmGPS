# **⏰ Smart WakeUp (Alarme Inteligente GPS)**

O **Smart WakeUp** é um aplicativo de despertador proativo e consciente do trânsito. Em vez de definir um horário fixo para acordar, você define **a hora que precisa chegar ao seu destino**. O aplicativo monitora o trânsito em tempo real enquanto você dorme e ajusta automaticamente o horário do seu alarme, garantindo que você nunca se atrase devido a engarrafamentos imprevistos.

## **✨ Principais Funcionalidades**

* 🚦 **Cálculo Dinâmico de Trânsito:** Integração com a API da *TomTom* para calcular rotas e verificar o tempo exato de deslocamento.  
* 🛡️ **Desarme Inteligente (Geofencing):** O app monitora sua localização em segundo plano. Se você sair de casa antes da hora, o alarme de "Saída" é desarmado automaticamente para não tocar enquanto você já está dirigindo.  
* 📍 **Gestão de Favoritos e Mapa Interativo:** Selecione locais clicando no mapa (*OpenStreetMap*), use seu GPS atual ou salve locais frequentes (como "Casa" ou "Trabalho") com sistema de auto-completar.  
* ⚡ **Ajuste de "Tempo pra Sair":** Configure quanto tempo você leva para se arrumar (banho, café). Possui suporte para `0 min` (para saídas imediatas, agrupando os alarmes).  
* 🌙 **Modo AMOLED e Temas:** Suporte nativo a Dark Mode otimizado para telas OLED (preto puro para economia de bateria) e paleta de cores customizável.  
* 📴 **Execução em Segundo Plano:** O app acorda silenciosamente o processador do celular 1 hora antes do seu alarme base para fazer a checagem na internet, sem gastar bateria durante a noite toda.

---

## **⚙️ Como Funciona (Lógica de Negócio)**

A inteligência do aplicativo reside na sua máquina de estados em background (Isolates do Dart).

1. **Agendamento Base:** Ao criar uma rotina (Ex: *Chegar às 08:00, trajeto de 30min, preparo de 40min*), o app agenda um "gatilho fantasma" para as 05:50 da manhã (1 hora antes do horário limite de acordar).  
2. **Verificação Silenciosa:** Às 05:50, o Android acorda apenas um fragmento de memória do app (`@pragma('vm:entry-point')`). Ele bate na API da TomTom.  
3. **Ajuste Matemático:** Se o trânsito estiver normal (30 min), os alarmes oficiais são cravados para 06:50 (Acordar) e 07:30 (Sair). Se houver um acidente e o trânsito pular para 50 min, os alarmes retrocedem dinamicamente, te acordando às 06:30 para compensar o atraso.  
4. **O Gatilho Final:** Dois minutos antes do alarme de "Sair" tocar, o GPS tira uma leitura rápida. Se a distância entre você e sua "Origem" for maior que 200 metros, o app entende que você já está no trânsito e silencia o aviso.

---

## **🛠️ Tecnologias e Pacotes Utilizados**

O projeto foi totalmente desenvolvido em **Flutter**, utilizando arquitetura orientada a objetos e boas práticas de gerenciamento de estado.

* **`flutter_map` & `latlong2`**: Renderização de mapas via tiles do OpenStreetMap e manipulação matemática de coordenadas.  
* **`http`**: Comunicação HTTP/REST para consumo da TomTom Routing API e da Nominatim API (Geocoding de endereços para coordenadas).  
* **`android_alarm_manager_plus`**: Escalador de processos no Android para executar código em horários exatos (Exact Alarms), contornando o Doze Mode do sistema operacional.  
* **`alarm`**: Pacote robusto para invocar a tela de Full Screen Intent (aquela que acende a tela do celular por cima da tela de bloqueio e toca o áudio em loop).  
* **`geolocator`**: Para captura de GPS de alta precisão e cálculo de distâncias (Geofencing).  
* **`shared_preferences`**: Banco de dados local em formato chave-valor (JSON) para persistência das rotinas, configurações de tema e favoritos, dispensando a necessidade de um banco SQL pesado.

---

## **🚀 Como rodar o projeto localmente**

### **Pré-requisitos**

* Flutter SDK instalado (Versão 3.x+).  
* Dispositivo Android físico ou Emulador (API 34+ recomendada).  
* Uma chave de API da TomTom (Crie uma conta em *developer.tomtom.com*).

### **Passo a Passo**

**Clone o repositório:**  
Bash  
git clone https://github.com/SEU\_USUARIO/smart-wakeup.git  
cd smart-wakeup

1. 

**Instale as dependências:**  
Bash  
flutter pub get

2.   
3. **Configure sua API Key:** Abra o arquivo `lib/main.dart`, procure pela variável `_tomTomKey` dentro da classe `ConfiguracaoRotinaTabState` e insira sua chave.

**Rode o aplicativo:**  
Bash  
flutter run

4. 

### **Geração de APK (Release)**

Para gerar um APK otimizado para o seu celular físico:

Bash  
flutter build apk \--release

*(O arquivo gerado estará em `build/app/outputs/flutter-apk/app-release.apk`)*

