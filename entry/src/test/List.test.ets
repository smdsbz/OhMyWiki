import localUnitTest from './LocalUnit.test';
import htmlDomTest from './HtmlDom.test';
import htmlParserTest from './HtmlParser.test';

export default function testsuite() {
  localUnitTest();
  htmlDomTest();
  htmlParserTest();
}
