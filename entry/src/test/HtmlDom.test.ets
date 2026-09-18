import { describe, it, expect } from '@ohos/hypium';
import { DomNode, HtmlDomBuilder, decodeEntities, findFirst, textOf } from '../main/ets/wiki/parser/htmldom/HtmlDom';

function build(html: string): DomNode {
  return new HtmlDomBuilder().build(html);
}

export default function htmlDomTest() {
  describe('HtmlDomTest', () => {
    it('basicTree', 0, () => {
      const root = build('<div><p>hello</p><p>world</p></div>');
      const div = root.children[0];
      expect(div.tag).assertEqual('div');
      expect(div.children.length).assertEqual(2);
      expect(div.children[0].tag).assertEqual('p');
      expect(div.children[0].children[0].text).assertEqual('hello');
    });

    it('impliedEndLi', 0, () => {
      const root = build('<ul><li>a<li>b</ul>');
      const ul = root.children[0];
      expect(ul.tag).assertEqual('ul');
      expect(ul.children.length).assertEqual(2);
      expect(ul.children[0].tag).assertEqual('li');
      expect(ul.children[1].children[0].text).assertEqual('b');
    });

    it('impliedEndTdTh', 0, () => {
      const root = build('<table><tr><td>1<td>2<th>3</tr></table>');
      const tr = root.children[0].children[0];
      expect(tr.tag).assertEqual('tr');
      expect(tr.children.length).assertEqual(3);
      expect(tr.children[0].tag).assertEqual('td');
      expect(tr.children[1].tag).assertEqual('td');
      expect(tr.children[2].tag).assertEqual('th');
    });

    it('voidAndSelfClosing', 0, () => {
      const root = build('<p><img src="x.png"><br><br/>after</p>');
      const p = root.children[0];
      expect(p.tag).assertEqual('p');
      expect(p.children[0].tag).assertEqual('img');
      expect(p.children[0].attr('src')).assertEqual('x.png');
      expect(p.children[1].tag).assertEqual('br');
      expect(p.children[3].text).assertEqual('after');
    });

    it('entities', 0, () => {
      expect(decodeEntities('a&amp;b')).assertEqual('a&b');
      expect(decodeEntities('&lt;x&gt;')).assertEqual('<x>');
      expect(decodeEntities('&#65;&#x42;')).assertEqual('AB');
      expect(decodeEntities('&nbsp;')).assertEqual('\u00A0');
      // 无分号宽容跳过
      expect(decodeEntities('a & b')).assertEqual('a & b');
      const root = build('<p title="a&amp;b">x</p>');
      expect(root.children[0].attr('title')).assertEqual('a&b');
    });

    it('gtInsideQuotedAttr', 0, () => {
      const root = build('<a title="a>b" href="x">t</a>');
      const a = root.children[0];
      expect(a.tag).assertEqual('a');
      expect(a.attr('title')).assertEqual('a>b');
      expect(a.children[0].text).assertEqual('t');
    });

    it('commentsAndDoctypeSkipped', 0, () => {
      const root = build('<!doctype html><!-- c --><div>x</div>');
      expect(root.children.length).assertEqual(1);
      expect(root.children[0].tag).assertEqual('div');
    });

    it('unmatchedEndTagIgnored', 0, () => {
      const root = build('<div>x</span></div>y');
      expect(root.children.length).assertEqual(2);
      // textOf 为 textContent 语义：兄弟文本节点间不加分隔符
      expect(textOf(root)).assertEqual('xy');
    });

    it('findFirstAndTextOf', 0, () => {
      const root = build('<div><span id="t">a</span><span>b</span></div>');
      const hit = findFirst(root, (el: DomNode) => el.attr('id') === 't');
      expect(hit === null ? '' : textOf(hit)).assertEqual('a');
    });

    it('largeDocPerformance', 0, () => {
      // 合成 ~1MB 文档（约 2 万标签），验证建树耗时量级
      let cell = '<tr><td class="bc_odd" style="background-color:#FFE8E0;">村下3</td>' +
        '<td><img src="../images/quest/quest4.png" width="16px" height="16px"> ' +
        '<span class="sp_only"><span style="color:green;">村下3</span> [<a href="../data/2400.html">古代林</a>]<br> </span>' +
        '<a href="../ida/220173.html">波乱的萌芽</a></td>' +
        '<td><div class="progress"><div class="progress-bar progress-bar-success" style="width:30%"></div></div></td></tr>';
      let html = '<html><body><div id="main_1"><table class="t1"><tbody>';
      for (let i = 0; i < 2500; i++) {
        html += cell;
      }
      html += '</tbody></table></div></body></html>';
      const start = Date.now();
      const root = new HtmlDomBuilder().build(html);
      const cost = Date.now() - start;
      expect(root.children.length).assertEqual(1);
      console.info(`HtmlDom large doc: ${Math.round(html.length / 1024)}KB built in ${cost}ms`);
      expect(cost < 5000).assertTrue();
    });
  });
}
