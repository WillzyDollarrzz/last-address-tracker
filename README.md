# Last Address Tracker on Solana

A script that tracks the last address an address sent to. **(only on solana, currently)**

**how it works ?**
- fetches the last address the startAddress sent to and does the same for the "sent to" address i.e
- addressA sent (amount) SOL -> addressB last. 
- addressB sent (amount) SOL -> addressC last. 
- limit is set to 100, you can change it in .env file... **"HOP = 100"** (just edit "100" to your desired no.)
- it is all stored in chain_output.txt <br/>
  
In this guide, we're using GitHub CodeSpaces <br/>

**Let's get started :)**

  - Paste this in your terminal:
    
```bash
mkdir lat && cd lat && wget -q https://raw.githubusercontent.com/WillzyDollarrzz/last-address-tracker/refs/heads/main/lat.sh && chmod +x lat.sh && ./lat.sh
```
