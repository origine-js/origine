// The root module of the recipe. Its './greet.js' import is resolved by the handler's relative() layer
// and read through the graph's fs grant, then evaluated before this module's own body.
import { greeting } from './greet.js';

print('recipe:', greeting);
