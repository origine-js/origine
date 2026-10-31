// Records the graph glue hands to init JS: requests and results of handlers, the graph itself. Built from `Data`.
import { Data } from '../handles.js';
import { seal } from '../util.js';
export class CodeCacheKey extends Data {}
export class PipelineResult extends Data {}
export class MetaRequest extends Data {}
export class ResolveRequest extends Data {}
export class ResolvedImport extends Data {}
export class ProvidedSource extends Data {}
export class MakerRequest extends Data {}
export class TransformResult extends Data {}
export class ModuleRequest extends Data {}
export class Graph extends Data {}
export class GraphFs extends Data {}
seal(CodeCacheKey, PipelineResult, MetaRequest, ResolveRequest, ResolvedImport, ProvidedSource, MakerRequest, TransformResult, ModuleRequest, Graph, GraphFs);
