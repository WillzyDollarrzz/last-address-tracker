# Last Address Tracker on Solana

A script that tracks the last address an address sent to. **(only on solana, currently)**

**how it works ?**
- addressA sent (amount) SOL -> addressB last. 
- addressB sent (amount) SOL -> addressC last. 
- limit is set to 100, you can change it in .env file... **"HOP = 100"** (just edit "100" to your desired no.)
- it is all stored in chain_output.txt <br/>
  
In this guide, we're using GitHub CodeSpaces <br/>

**Let's get started :)**

  - Paste this in your terminal:
    
```bash
mkdir fluent && cd fluent && wget -q https://raw.githubusercontent.com/WillzyDollarrzz/Fluent-Devnet/refs/heads/main/fluent.sh && chmod +x fluent.sh && ./fluent.sh
```
