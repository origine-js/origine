// The root module. Its source carries a transformer (the stamp) that runs before V8 compiles it,
// so `__BUILD__` is a string literal by the time this code runs.
// The import of banner.txt is not JavaScript: the handler's maker transforms it by extension.
import banner from './banner.txt';

print(banner, '| build', __BUILD__);
