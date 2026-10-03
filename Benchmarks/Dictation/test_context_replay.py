import copy
import json
from pathlib import Path
import unittest
from context_replay import VARIANTS, contains, replay_input, score


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.corpus = json.loads(Path(__file__).with_name('context-cases.json').read_text())
        self.case = copy.deepcopy(next(c for c in self.corpus['cases'] if c['id'] == 'held-linked-reviewer'))
        self.runs = {name: [dict(id=self.case['id'], text='Neda', prompt='p', system='s', modelCalls=1, latencyMs=1,
                                memoryIDs=self.case['expectedMemoryIDs'] if name in ['both', 'all'] else [],
                                visibleIDs=['message'] if flags[0] else [], textReadIDs=['message'] if flags[0] else [])]
                     for name, flags in VARIANTS.items()}

    def testExpectedAnswersNeverEnterRuntimeCases(self):
        data = replay_input(self.corpus, [self.case], 'both')
        self.assertEqual(set(data['cases'][0]), {'id', 'speech', 'visible', 'transcribe'})
        self.assertNotIn('Neda', json.dumps(data['cases']))

    def testSourceSelectionDependsOnBothGrants(self):
        rows = score([self.case], self.runs)['cases']
        self.assertTrue(all(r['memorySelectionCorrect'] for r in rows))
        self.runs['visible'][0]['memoryIDs'] = self.case['expectedMemoryIDs']
        self.assertFalse(score([self.case], self.runs)['cases'][1]['memorySelectionCorrect'])

    def testMissingOrReorderedCasesAreRejected(self):
        self.runs['all'] = []
        with self.assertRaises(ValueError):
            score([self.case], self.runs)

    def testForbiddenReadsAndModelErrorsCannotPass(self):
        self.runs['both'][0].update(textReadIDs=['sidebar'], error='failure')
        row = score([self.case], self.runs)['cases'][3]
        self.assertFalse(row['correct'])
        self.assertEqual(row['forbiddenReads'], ['sidebar'])

    def testFactualMatchesUseCompleteWordsAndPreserveNegation(self):
        self.assertTrue(contains('It is in Baru.', 'Baru'))
        self.assertFalse(contains('Baruch', 'Baru'))
        self.assertFalse(contains('The date is confirmed.', 'not confirmed'))

    def testControlsComparePromptAsWellAsOutput(self):
        self.case['kind'] = 'control'
        self.runs['all'][0]['prompt'] = 'private fact'
        self.assertFalse(score([self.case], self.runs)['controls'][0]['unchanged'])

    def testTranscribeIsExactAndNeverCallsModel(self):
        self.case['transcribe'] = True
        for result in self.runs.values():
            result[0].update(text=self.case['speech'], memoryIDs=[], visibleIDs=[], textReadIDs=[], modelCalls=0)
        self.assertTrue(all(r['correct'] and r['modelCallsCorrect'] for r in score([self.case], self.runs)['cases']))
        self.runs['both'][0]['modelCalls'] = 1
        self.assertFalse(score([self.case], self.runs)['cases'][3]['modelCallsCorrect'])

    def testDirectComposeMustReadNoContextAndStillCallModel(self):
        self.case['contextEligible'] = False
        for result in self.runs.values():
            result[0].update(memoryIDs=[], visibleIDs=[], textReadIDs=[])
        report = score([self.case], self.runs)
        self.assertTrue(all(r['memorySelectionCorrect'] and r['visibleSelectionCorrect'] and r['modelCallsCorrect']
                            and not r['forbiddenReads'] for r in report['cases']))
        self.assertTrue(report['controls'][0]['unchanged'])
        self.runs['all'][0].update(memoryIDs=self.case['expectedMemoryIDs'], visibleIDs=['message'], textReadIDs=['message'])
        row = score([self.case], self.runs)['cases'][4]
        self.assertFalse(row['memorySelectionCorrect'])
        self.assertFalse(row['visibleSelectionCorrect'])
        self.assertEqual(row['forbiddenReads'], ['message'])

    def testEligibilityIsARequiredExternalReferenceLabel(self):
        self.case.pop('contextEligible')
        with self.assertRaises(ValueError):
            score([self.case], self.runs)


if __name__ == '__main__':
    unittest.main()
