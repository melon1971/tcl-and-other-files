1| # tcl-and-other-files
2| 
3| This repository collects the current release files, source archives, helper scripts, and related documentation for a few independent projects that I distribute here for convenience.
4| 
5| ## Repository files by type
6| 
7| ### Tcl and Tcl-related scripts (.tcl)
8| - `guard.tcl`
9| - `mafia.tcl`
10| - `masterhelp.tcl`
11| - `mem.tcl`
12| - `restrict.tcl`
13| - `spychan.tcl`
14| - `sysinfo.tcl`
15| - `talkbot.tcl`
16| - `talkbot_cost.tcl`
17| - `whocom.tcl`
18| 
19| ### Data and configuration files (.conf, .cfg, .sqlite3)
20| - `60-scanistry-hardening.conf`
21| - `99-hardening_1.conf`
22| - `Mafia.cfg`
23| - `mafia.sqlite3`
24| 
25| ### Documentation and guides (.docx)
26| - `ClamAV-upgrade-trixie.docx`
27| - `LiveWorld-RPG-Guide.docx`
28| - `Scanistry-Ignores-and-Blocks.docx`
29| - `Scanistry-Installation-Guide-5_0-23.docx`
30| 
31| ### Packages and archives (.deb, .tar.gz, .zip, .diff)
32| - `scanistry_5.0-23_amd64.deb`
33| - `liveworld-rpg_1.0.36_all.deb`
34| - `scanistry-5.0-23-source.tar.gz`
35| - `liveworld-rpg-1.0.36-source.tar.gz`
36| - `netbots4.11.zip`
37| - `netbots-4.10-to-4.11.diff`
38| 
39| ### Validation and release files (.sh, .txt)
40| - `scanistry-vm-check.sh`
41| - `SHA256SUMS-5.0-23.txt`
42| - `SHA256SUMS-1.0.36.txt`
43| 
44| ## Current uploads
45| 
46| ### Scanistry
47| 
48| - [scanistry_5.0-23_amd64.deb](scanistry_5.0-23_amd64.deb) — Debian package for the current Scanistry release
49| - [scanistry-5.0-23-source.tar.gz](scanistry-5.0-23-source.tar.gz) — source archive for the same release
50| - [scanistry-vm-check.sh](scanistry-vm-check.sh) — post-install verification script
51| - [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt) — checksums for the release files
52| - [Scanistry-Installation-Guide-5_0-23.docx](Scanistry-Installation-Guide-5_0-23.docx) — installation guide
53| - [Scanistry-Ignores-and-Blocks.docx](Scanistry-Ignores-and-Blocks.docx) — notes on ignore rules and block handling
54| - [ClamAV-upgrade-trixie.docx](ClamAV-upgrade-trixie.docx) — ClamAV upgrade guidance
55| 
56| ### LiveWorld RPG
57| 
58| - [liveworld-rpg_1.0.36_all.deb](liveworld-rpg_1.0.36_all.deb) — Debian package
59| - [liveworld-rpg-1.0.36-source.tar.gz](liveworld-rpg-1.0.36-source.tar.gz) — source archive
60| - [SHA256SUMS-1.0.36.txt](SHA256SUMS-1.0.36.txt) — checksums for the LiveWorld release
61| - [LiveWorld-RPG-Guide.docx](LiveWorld-RPG-Guide.docx) — game guide
62| 
63| ### Eggdrop / Tcl scripts
64| 
65| - [masterhelp.tcl](masterhelp.tcl) — Eggdrop help-menu script
66| - [guard.tcl](guard.tcl)
67| - [mafia.tcl](mafia.tcl)
68| - [mafia.sqlite3](mafia.sqlite3)
69| - [mem.tcl](mem.tcl)
70| - [restrict.tcl](restrict.tcl)
71| - [spychan.tcl](spychan.tcl)
72| - [sysinfo.tcl](sysinfo.tcl)
73| - [talkbot.tcl](talkbot.tcl)
74| - [talkbot_cost.tcl](talkbot_cost.tcl)
75| - [whocom.tcl](whocom.tcl)
76| - [netbots4.11.zip](netbots4.11.zip)
77| - [netbots-4.10-to-4.11.diff](netbots-4.10-to-4.11.diff)
78| - [Mafia.cfg](Mafia.cfg)
79| 
80| ### System config examples
81| 
82| - [60-scanistry-hardening.conf](60-scanistry-hardening.conf)
83| - [99-hardening_1.conf](99-hardening_1.conf)
84| 
85| ---
86| 
87| # Scanistry — Local Host Security Daemon
88| 
89| Scanistry is a local host security daemon and dashboard for a single Linux machine. It coordinates standard tools such as UFW/nftables, Suricata, ClamAV, AIDE, Lynis, rkhunter, and debsecan into a single dashboard-driven workflow.
90| 
91| ## Current release
92| 
93| - Version: 5.0-23
94| - Package: `scanistry`
95| - Current Debian package: [scanistry_5.0-23_amd64.deb](scanistry_5.0-23_amd64.deb)
96| - Source: [scanistry-5.0-23-source.tar.gz](scanistry-5.0-23-source.tar.gz)
97| - Check script: [scanistry-vm-check.sh](scanistry-vm-check.sh)
98| - Integrity hashes: [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt)
99| 
100| Install it with:
101| 
102| ```bash
103| sudo apt install -y ./scanistry_5.0-23_amd64.deb
104| ```
105| 
106| ## What it does
107| 
108| - firewall control and auto-blocking
109| - network intrusion detection with Suricata
110| - malware scanning with ClamAV
110| - file-integrity monitoring with AIDE
111| - hardening audit with Lynis
112| - rootkit checks with rkhunter
113| - CVE and package auditing
114| - local dashboard and API over HTTPS
115| 
116| See the package documentation and the install guide for the full feature set and operational details.
117| 
118| ---
| 
119| # masterhelp.tcl — Eggdrop Help Menu Script
120| 
121| `masterhelp.tcl` is a Tcl script that provides a help-menu system for Eggdrop IRC bots. It indexes and organizes commands and references into a structure that can be browsed from the bot.
122| 
123| ## Included Eggdrop scripts
124| 
125| This repository contains a set of related Eggdrop scripts and references intended to pair with the help menu, including:
126| 
127| - `guard.tcl`
128| - `mafia.tcl`
129| - `mem.tcl`
130| - `restrict.tcl`
131| - `spychan.tcl`
132| - `sysinfo.tcl`
133| - `talkbot.tcl`
134| - `talkbot_cost.tcl`
135| - `whocom.tcl`
136| 
137| ---
138| 
139| # Eggdrop on Debian 13 (Trixie) — Package Requirements
140| 
141| The Eggdrop scripts in this repository are intended for Debian 13 and related Debian-based systems. The exact package set depends on which script you load and which features you use.
142| 
143| Typical requirements include the packages needed for Tcl, IRC, networking, and script support. See the project files in this repo for the relevant package lists and notes.
144| 
145| ## Eggdrop / Tcl scripts
146| 
147| ```bash
148| sudo apt update
149| sudo apt install -y \
150|   eggdrop \
151|   tcl8.6 \
152|   tcl-tls \
153|   tcllib \
154|   libsqlite3-tcl \
155|   ca-certificates \
156|   coreutils \
157|   openssl \
158|   curl \
159|   build-essential \
160|   libssl-dev \
161|   zlib1g-dev
162| ```
163| 
164| These are the packages most commonly needed by the Eggdrop bot and the Tcl scripts in this repository:
165| 
166| - `eggdrop` — IRC bot runtime
167| - `tcl8.6` — Tcl interpreter for the scripts
168| - `tcl-tls` — TLS/HTTPS support for scripts such as `talkbot.tcl` and `whocom.tcl`
169| - `tcllib` ��� helper libraries such as `json`
170| - `libsqlite3-tcl` — SQLite support for scripts such as `mafia.tcl`
171| - `ca-certificates` — trust chain for HTTPS/TLS connections
172| - `coreutils` — standard Unix utilities such as `df`, `ls`, `cat`, and `sort`
173| - `openssl` and `curl` — useful for HTTPS API access and testing
174| - `build-essential`, `libssl-dev`, and `zlib1g-dev` — for source builds or compilation work
175| 
176| ## TLS-capable bot / API scripts
177| 
178| If you run scripts that connect to hosted APIs or use HTTPS features, make sure these are installed:
179| 
180| ```bash
181| sudo apt install -y \
182|   tcl-tls \
183|   ca-certificates \
184|   openssl \
185|   curl \
186|   tcllib
187| ```
188| 
189| These packages are especially relevant for bot scripts that call external services or fetch data over TLS.
190| 
191| ## Scanistry
192| 
193| Scanistry is a local host security and monitoring stack. The package itself pulls in most of the required tools, but the general dependency set is:
194| 
195| ```bash
196| sudo apt install -y \
197|   ufw \
198|   nftables \
199|   aide \
200|   lynis \
201|   debsecan \
202|   rkhunter \
203|   clamav \
204|   clamav-daemon \
205|   freshclam \
206|   suricata \
207|   suricata-update \
208|   tshark \
209|   tcpdump \
210|   apparmor-utils \
211|   libcap2-bin \
212|   python3-pyqt6 \
213|   python3-pyqt6.qtwebengine \
214|   rsyslog \
215|   policykit-1 \
216|   pkexec
217| ```
218| 
219| Useful extras for the desktop side and service control:
220| 
221| ```bash
222| sudo apt install -y \
223|   mate-polkit \
224|   polkit-gnome \
225|   dunst \
226|   xfce4-notifyd \
227|   gnome-shell-extension-appindicator
228| ```
229| 
230| ## LiveWorld RPG
231| 
231| LiveWorld RPG is a Python/Pygame game and has the usual runtime dependencies:
232| 
233| ```bash
234| sudo apt install -y \
235|   python3 \
236|   python3-pygame \
237|   python3-numpy \
238|   x11-utils
239| ```
240| 
241| Optional extras:
242| 
243| ```bash
244| sudo apt install -y \
245|   python3-tk \
246|   python3-pil \
247|   python3-pip
248| ```
249| 
250| ## Common support packages
251| 
252| These are useful across the repository and for general Debian 13 use:
253| 
254| ```bash
255| sudo apt install -y \
256|   build-essential \
257|   git \
258|   curl \
259|   procps \
260|   net-tools \
261|   jq \
262|   rsyslog \
263|   ca-certificates
264| ```
265| 
266| ## Recommended all-in-one install for Debian 13
267| 
268| If you want a practical starting point for the Eggdrop/Tcl side of this repository, a good base install is:
269| 
270| ```bash
271| sudo apt update
272| sudo apt install -y \
273|   eggdrop \
274|   tcl8.6 \
275|   tcl-tls \
276|   tcllib \
277|   libsqlite3-tcl \
278|   ca-certificates \
279|   openssl \
280|   curl \
281|   build-essential \
282|   libssl-dev \
283|   zlib1g-dev \
284|   git \
285|   coreutils \
286|   procps \
287|   net-tools \
288|   jq
289| ```
290| 
291| ## Before loading
292| 
293| - Load the main script first, not the `_data.tcl` file it depends on.
294| - Run Eggdrop as a normal user, not as root.
295| - For `whocom.tcl`, outbound port 43 is needed for raw WHOIS requests; `!dom` falls back to HTTPS lookups if needed.
296| 
297| ## Verify the packages load
298| 
299| ```bash
300| echo 'puts [package require tls]; puts [package require sqlite3]; puts [package require json]' | tclsh8.6
301| ```
302| 
303| ---
304| 
305| # LiveWorld RPG — Offline Fantasy RPG
306| 
307| **Version 1.0.36** · Package: `liveworld-rpg`
308| 
309| LiveWorld RPG is an offline, single-player fantasy RPG with isometric 2.5D graphics, written in Python with pygame. You play in a large living world with 12 classes, instanced dungeons and raids, PvP battles, and a full quest, crafting, and guild-driven system.
310| 
311| ---
312| 
313| # Useful files and notes
314| 
315| - [README.md](README.md) — repository index and overview
316| - [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt) — current file integrity hashes for the Scanistry release
317| - [Scanistry-Installation-Guide-5_0-23.docx](Scanistry-Installation-Guide-5_0-23.docx) — setup and migration notes
318| - [ClamAV-upgrade-trixie.docx](ClamAV-upgrade-trixie.docx) — Debian 13 ClamAV notes
319| - [Scanistry-Ignores-and-Blocks.docx](Scanistry-Ignores-and-Blocks.docx) — ignore/block behavior explanations
320| 
321| This repository is intended as a package and documentation mirror for the current uploads. New builds, source archives, and documentation are uploaded here as they are produced.
322| 