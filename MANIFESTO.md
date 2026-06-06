# LunarWing Manifesto/Philosophy

#### Inspired by: 

* Manifesto for a Democratic Civilization Part 3 by Abdullah Öcalan
* Agorism in the 21st Century, Volumes I and II
* https://www.gnu.org/philosophy/philosophy.html
* https://dark.fi/manifesto.html
* Thus Spoke Zarathustra by Friedrich Nietzsche
* Proofs, Arguments, and Zero-Knowledge by Justin Thaler.

##### LunarWing is NOT a corporate startup with VC Seed Funding. We DO NOT sell access to LLMs and we are NOT NearAI or affiliated with NearAI. See README.md for more information.

##### LunarWing supports autonomous political formations.

##### LunarWing supports the Free Software Foundation.

##### LunarWing supports freedom, user choice, locally hosted LLM set ups, various TEE environments, and even less secure options of using LLMs. It is entirely up to the user how much trust he or she has in their third party model backend providers. In the end, we prioritize for security in this department. Additionally, the way the system is architected, secrets are never exposed to any LLM which you choose to use. When a WASM tool or WASM channel utilizes secrets, they should not be exposed in plaintext. The core concept is, any LLM regardless of where it's hosted, does not have the ability to read secrets.

While we do support user choice, we do not necessarily want to pander to those who ask us to support x, y, or z kind of agent communication channel out of the box besides the ones which are core to the LunarWing project. This certainly means that no, we won't officially support proprietary communication channels, even if the code currently exists in the repo. Users can use it, but it will certainly not be updated or supported in the future. The team may, at its own discretion, even choose to entirely remove any or all of these channel source code components in the repo which disagrees with our philosophy (This process has already started and will continue). This is our main hardline stance. You have been warned. The LunarWing team uses secure, private, self-hostable communication methods such as IRC with end to end encryption on the plugin level (See: Enjin, part of seperate repo), DarkIRC, and XMPP MUC/1:1 chat with built in OMEMO encryption via a bridge layer. We do use various locally developed MCP servers as well for our agents. We utilize our own notification servers (Gotify) and do not use Google services either, so these will also not be supported or given any love going forward. In the future, we would be open to exploring new communication channels to maintain in this repo, as long as they maintain free and open standards.

We won't force users to NOT use proprietary channels maintained by third party companies. We simply won't support it in our official repo. Others are free to build and maintain such tools and there are working examples already.

We are a small group with very opinionated backgrounds in technology. Our own opinions and philosophy will have an impact on this project going forward. Our opinions, experience, and philosophy affect the overall direction and focus of the project.

Addendum: We believe that local inference with open weight models is the future. While the engineers of LunarWing still have a lot to learn about tuning models or developing custom clients to accomodate specialized models, we still believe that we should prioritize LOCAL inference in our project. We believe our underlying philosophical beliefs meshes perfectly with utilizing your own hardware on your own network, utilizing models that you can control. 
