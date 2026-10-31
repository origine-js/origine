// The realm shares these exact constructors with its API glue.
const { classes } = import.meta.native;
delete import.meta.native;
export const OrigineError = classes.OrigineError;
export const IoError = classes.IoError;
export const HostError = classes.HostError;
export const ImportError = classes.ImportError;
export const ModuleError = classes.ModuleError;
