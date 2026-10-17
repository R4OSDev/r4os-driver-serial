# R4OS Serial driver

SERIAL.R4D 0.1.0 provides independent 16550-compatible UART ports through the
common COM application API. Requires Kernel0.1.321/DriverApi37. Normal UART
registers, buffers and IRQs belong here; catalog ownership and waits are kernel
mediation. COM1 remains untouched while its early debug claim is active.

Build with Build.sh or Build.bat. Host paths come from Settings.R4S. The initial
hardware scope is declared classic I/O UART resources, including more than two,
and explicitly configured compatible PCI BAR resources. Generic PCI/USB serial
hotplug discovery is future work using the same application contract.

Configuration, semantics and concrete validation limits: DOCUMENTATION.de.txt.
