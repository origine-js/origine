// The entry module, read from disk. Its three kinds of import are each answered by a different hook.
import { greet } from './lib/helper.js'; // a file: fsProvider
import { answer } from 'virtual:answer'; // no file: a hook provides the text
import { encodeUtf8 } from 'origine:@std/text'; // a host module: origineProvider, 'text' is included

print(greet('hooks'), '| answer', answer, '| utf8 bytes', encodeUtf8('é').length);
