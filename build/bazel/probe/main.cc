extern "C" unsigned origine_probe_zig(unsigned);

// Accepts and returns values; retains no resources.
int main() { return origine_probe_zig(5) == 66 ? 0 : 1; }
