export interface Greeting {
  text: string;
}

export const greet = (name: string): Greeting => ({ text: `hello, ${name}` });
