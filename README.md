# R4OS Serial driver

SERIAL.R4D 0.1.1 provides independent 16550-compatible UART ports through the
common COM application API. Requires a DriverApi2 platform (qualified with Kernel0.1.474/SDK192). Normal UART
registers, buffers and IRQs belong here; catalog ownership and waits are kernel
mediation. COM1 remains untouched while its early debug claim is active.

Build with Build.sh or Build.bat. Host paths come from Settings.R4S. The initial
hardware scope is declared classic I/O UART resources, including more than two,
and explicitly configured compatible PCI BAR resources. Generic PCI/USB serial
hotplug discovery is future work using the same application contract.

Configuration, semantics and concrete validation limits: DOCUMENTATION.de.txt.

Version0.1.1 uses real DriverInit2/DriverApi2 and R4DEV:Query2:2. The independent serial/heap records retain revision1 and exact registration/generation ownership. IRQ service uses the existing pure SDK IRQ budget with the original64 causes; no sleep or wait occurs in that scope. Unregister drains exact port calls before generic module admission closes. Build.sh test / Build.bat test now compiles the actual owner, replacing obsolete references to absent RTL8139 test files: partial read/write status, bounded IRQ fault, and retained UART until THRE plus TEMT. Host tests replace register access and privileged IF manipulation only; native UART and Windows execution need separate evidence.
