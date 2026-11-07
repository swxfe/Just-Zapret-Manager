@echo off
set "BIN=%~dp0bin\"
start "zapret" /min "%BIN%winws.exe" --wf-tcp=80,443 --wf-udp=443 ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%BIN%ACTIVE_DISCORD_UDP.bin" --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --dpi-desync=multisplit --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --dpi-desync=multisplit --dpi-desync-any-protocol=1 --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --dpi-desync-repeats=8 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-udp=%GameFilterUDP% --dpi-desync=fake --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%ACTIVE_GAME_UDP.bin"
